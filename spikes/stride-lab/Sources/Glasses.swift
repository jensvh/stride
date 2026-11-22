import AVFoundation
import CoreMedia
import Foundation
import MWDATCamera
import MWDATCore
import MWDATInputs
import UIKit

// MARK: - Small helpers

/// The state of one part of the glasses link, as shown in the status strip.
enum Phase: Equatable {
    case off, starting, on, paused, stopping
    case failed(String)

    var label: String {
        switch self {
        case .off: return "off"
        case .starting: return "starting"
        case .on: return "on"
        case .paused: return "paused"
        case .stopping: return "stopping"
        case .failed(let why): return "failed: \(why)"
        }
    }
}

/// Lets exactly one of several racers win.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Checks a condition every `step` seconds until it holds or `seconds` pass.
@MainActor
func waitUntil(_ seconds: Double, step: Double = 0.1, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > end || Task.isCancelled { return condition() }
        try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
    }
    return true
}

/// Runs `op` and reports whether it finished within `seconds`. If not, it is
/// cancelled and abandoned, so a hanging toolkit call can't block the app.
@MainActor
func finishes(within seconds: Double, _ op: @escaping @MainActor () async -> Void) async -> Bool {
    let worker = Task { @MainActor in await op() }
    return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
        let once = Once()
        Task { await worker.value; if once.claim() { done.resume(returning: true) } }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() { worker.cancel(); done.resume(returning: false) }
        }
    }
}

// MARK: - Glasses

/// Everything that goes through Meta's Device Access Toolkit, coordinated so
/// that it can't get stuck:
/// - one action at a time (`run`), each with a time limit;
/// - each camera, display and inputs instance has a generation number, and
///   callbacks from an older one are ignored (no more "press Stop twice");
/// - closing is confirmed, in the order of Meta's samples: inputs, display,
///   camera, then the session. A camera that doesn't confirm its stop takes
///   the session down with it, which releases it on the glasses;
/// - one session is shared by all tests while it is healthy, at least 2 s
///   between sessions, one retry, closed after a minute of disuse.
///
/// Rules of the glasses this follows (Meta's developer forum):
/// the back gesture ends the app on the glasses (ios#349); one tap pauses a
/// session, a second tap resumes (ios#312); keep one session and re-add the
/// camera instead of restarting a stopped stream (ios#292, #260).
@MainActor
final class Glasses: ObservableObject {
    // Registration and device
    @Published private(set) var registration = "unknown"
    @Published private(set) var registered = false
    @Published private(set) var devices = 0
    @Published private(set) var deviceInfo = "no glasses listed"
    @Published private(set) var connected = false
    @Published private(set) var worn = false
    @Published private(set) var banner: String?

    // What is open, what is running
    @Published private(set) var sessionPhase: Phase = .off { didSet { if sessionPhase != oldValue { resourcesChanged?() } } }
    @Published private(set) var cameraPhase: Phase = .off { didSet { if cameraPhase != oldValue { resourcesChanged?() } } }
    @Published private(set) var status = ""
    @Published private(set) var busy: String?

    // Camera, photo and the microphone on the camera stream
    @Published private(set) var frame: UIImage?
    @Published private(set) var frames = 0
    @Published private(set) var fps: Double = 0
    @Published private(set) var photo: UIImage?
    @Published private(set) var photoMs: Int?
    @Published private(set) var photoCount = 0
    @Published private(set) var micFrames = 0
    @Published private(set) var micLevel: Double = 0
    @Published private(set) var micRate: Double = 0
    /// HEVC frames are shown on `preview`; raw ones as `frame`.
    @Published private(set) var previewing = false
    let preview = FramePreview()
    let display = GlassesDisplay()

    var onLog: ((String) -> Void)?
    /// Called when something opens or closes (for the unclean-exit marker).
    var resourcesChanged: (() -> Void)?
    /// The screen-off round keeps the session between its steps.
    var keepSessionOpen = false

    private let wearables = Wearables.shared
    private var deviceTokens: [any AnyListenerToken] = []
    private var wasConnected = false
    private var wasWorn = false

    private var session: DeviceSession?
    private var sessionGen = 0
    private var sessionTasks: [Task<Void, Never>] = []
    private var closingSession = false
    private var lastSessionEnd = Date.distantPast
    private var pauseTimer: Task<Void, Never>?
    private var idleTimer: Task<Void, Never>?
    private var sessionRefusals = 0

    private var camera: Camera?
    private var cameraGen = 0
    private var cameraTokens: [any AnyListenerToken] = []
    private var closingCamera = false
    private var streamStarted = false
    private var cameraRefusals = 0
    private var fpsWindow: [Date] = []
    private var photoAskedAt: Date?
    private var showFrames = true
    private let micMeter = MicMeter()

    private var lastWork: Task<Void, Never>?
    private var currentWorker: Task<Void, Never>?
    private var queueGen = 0
    private var busyID = UUID()

    init() {
        display.onLog = { [weak self] text in self?.onLog?(text) }
        display.onClosePressed = { [weak self] in
            self?.run("closing the card") { await self?.display.closeDisplay() }
        }
        Task { [weak self] in
            guard let self else { return }
            for await state in self.wearables.registrationStateStream() {
                self.registration = String(describing: state)
                let was = self.registered
                self.registered = state == .registered
                self.onLog?("registration: \(state)")
                if was && !self.registered && self.session != nil {
                    self.run("registration lost") { await self.closeSession("the registration was lost") }
                }
                self.updateBanner()
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await list in self.wearables.devicesStream() {
                self.devices = list.count
                self.onLog?("glasses listed: \(list.count)")
                self.watchDevices(list)
            }
        }
    }

    /// The line every glasses test shows under its buttons.
    func say(_ text: String) {
        status = text
        onLog?(text)
    }

    func clearStatus() {
        status = ""
        cameraRefusals = 0
        sessionRefusals = 0
        updateBanner()
    }

    var hasSession: Bool { session != nil }
    var cameraOpen: Bool { camera != nil }
    var cameraStreaming: Bool { cameraPhase == .on }
    var micPeak: Float { micMeter.peak }
    private var sessionInUse: Bool { camera != nil || display.isOpen || display.inputsOpen }

    // MARK: Action queue

    /// Runs one action at a time, in order. Each gets a time limit; when it
    /// takes longer it is abandoned with a message. `preempt` (the reset
    /// buttons) cancels the running action and drops the waiting ones.
    func run(_ label: String, timeout: Double = 30, preempt: Bool = false,
             _ work: @escaping @MainActor () async -> Void) {
        if preempt {
            queueGen += 1
            currentWorker?.cancel()
        }
        let gen = queueGen
        let previous = preempt ? nil : lastWork
        lastWork = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, gen == self.queueGen else { return }
            let id = UUID()
            self.busyID = id
            self.busy = label
            let worker = Task { @MainActor in await work() }
            self.currentWorker = worker
            let finished = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                let once = Once()
                Task { await worker.value; if once.claim() { done.resume(returning: true) } }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if once.claim() { worker.cancel(); done.resume(returning: false) }
                }
            }
            if !finished {
                self.say("“\(label)” took more than \(Int(timeout)) s and was stopped. If things stay stuck, use Reset.")
            }
            if self.busyID == id {
                self.busy = nil
                self.currentWorker = nil
            }
            self.scheduleIdleClose()
        }
    }

    // MARK: Devices

    private func watchDevices(_ ids: [DeviceIdentifier]) {
        cancel(&deviceTokens)
        for device in ids.compactMap({ wearables.deviceForIdentifier($0) }) {
            deviceTokens.append(device.addLinkStateListener { [weak self] _ in Task { @MainActor in self?.refreshDevice() } })
            deviceTokens.append(device.addCompatibilityListener { [weak self] _ in Task { @MainActor in self?.refreshDevice() } })
            deviceTokens.append(device.addDeviceStateListener { [weak self] _ in Task { @MainActor in self?.refreshDevice() } })
        }
        refreshDevice()
    }

    func refreshDevice() {
        guard let device = preferredDevice() else {
            deviceInfo = "no glasses listed"
            connected = false
            worn = false
            updateBanner()
            return
        }
        connected = device.linkState == .connected
        worn = device.donState == .donned
        let name = device.name.isEmpty ? "glasses" : device.name
        let info = "\(name): \(device.linkState), \(device.compatibility().displayString), \(device.donState)"
            + (device.supportsDisplay() ? ", has display" : ", no display")
            + (device.batteryLevel.map { $0 > 0 ? ", battery \($0)%" : "" } ?? "")
        if info != deviceInfo {
            deviceInfo = info
            onLog?("glasses: \(info)")
        }
        // Lost the link: whatever ran on it is gone.
        if wasConnected && !connected && session != nil {
            run("glasses disconnected") { await self.closeSession("the glasses disconnected") }
        }
        // Taken off: Meta's advice is to release the camera.
        if wasWorn && device.donState == .doffed && camera != nil {
            run("glasses taken off") {
                self.say("camera: the glasses were taken off")
                await self.closeCamera()
            }
        }
        wasConnected = connected
        wasWorn = worn
        updateBanner()
    }

    private func updateBanner() {
        if !registered {
            banner = "Not registered with the Meta AI app: open test 1 and tap Register."
        } else if devices == 0 {
            banner = "No glasses listed: check they are paired in the Meta AI app."
        } else if !connected {
            banner = "The glasses are not connected: open the Meta AI app and check they show as connected."
        } else if cameraRefusals >= 2 || sessionRefusals >= 2 {
            banner = "The glasses keep refusing. Switch them off and on with the power switch, then tap Reset → Reset glasses connection."
        } else {
            banner = nil
        }
    }

    /// Worn and connected first, then connected, then compatible.
    private func preferredDevice() -> Device? {
        let found = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        func rank(_ d: Device) -> Int {
            if d.linkState == .connected && d.donState == .donned { return 0 }
            if d.linkState == .connected { return 1 }
            if d.compatibility() == .compatible { return 2 }
            return 3
        }
        return found.min { rank($0) < rank($1) }
    }

    /// Listener tokens stop their listener only when cancelled.
    private func cancel(_ tokens: inout [any AnyListenerToken]) {
        let old = tokens
        tokens = []
        Task { for token in old { await token.cancel() } }
    }

    // MARK: Registration

    func register() {
        run("registering") {
            do {
                try await self.wearables.startRegistration()
                self.say("registration started: confirm in the Meta AI app")
            } catch {
                self.say("registration failed: \(error)")
            }
        }
    }

    func unregister() {
        run("unregistering") {
            await self.closeSession("unregistering")
            do { try await self.wearables.startUnregistration() } catch { self.say("unregister failed: \(error)") }
        }
    }

    /// The Meta AI app calls back through stridelab://…
    func handle(_ url: URL) {
        Task {
            do {
                let handled = try await wearables.handleUrl(url)
                onLog?(handled ? "Meta AI app answered" : "link not for the toolkit: \(url.absoluteString.prefix(60))")
            } catch {
                say("callback failed: \(error)")
            }
        }
    }

    // MARK: Session

    /// The open session if it is healthy, otherwise a new one.
    func ensureSession() async -> DeviceSession? {
        if let current = session {
            switch current.state {
            case .started:
                return current
            case .paused:
                say("The session is paused on the glasses: tap the side of the glasses once to resume.")
                return nil
            case .idle, .starting:
                if await waitUntil(10, step: 0.2, { current.state == .started }) { return current }
                await closeSession("it did not start", quiet: true)
            default:
                await closeSession("it was \(current.state)", quiet: true)
            }
        }
        for attempt in 1...2 {
            let (opened, retry) = await openSession()
            if let opened {
                sessionRefusals = 0
                updateBanner()
                return opened
            }
            guard retry, attempt == 1, !Task.isCancelled else { break }
            say("trying once more…")
        }
        sessionRefusals += 1
        updateBanner()
        return nil
    }

    private func openSession() async -> (DeviceSession?, Bool) {
        guard registered else {
            say("Not registered: tap Register with the Meta AI app in test 1 first.")
            return (nil, false)
        }
        if preferredDevice()?.linkState != .connected {
            _ = await waitUntil(5, step: 0.25) { self.preferredDevice()?.linkState == .connected }
        }
        guard let device = preferredDevice() else {
            say("No glasses listed. Check the glasses are paired in the Meta AI app.")
            return (nil, false)
        }
        guard device.linkState == .connected else {
            say("The glasses are not connected (\(device.linkState)). Open the Meta AI app, check they show as connected, then try again.")
            return (nil, false)
        }
        switch device.compatibility() {
        case .deviceUpdateRequired: say("The glasses need a software update (Meta AI app → glasses settings)."); return (nil, false)
        case .sdkUpdateRequired: say("These glasses need a newer toolkit version in Stride Lab."); return (nil, false)
        default: break
        }
        // Meta: leave at least 2 seconds between sessions.
        let gap = 2 - Date().timeIntervalSince(lastSessionEnd)
        if gap > 0 { try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000)) }
        if Task.isCancelled { return (nil, false) }

        say("opening a session on \(device.name.isEmpty ? "the glasses" : device.name)…")
        sessionGen += 1
        let gen = sessionGen
        sessionPhase = .starting
        do {
            let opened = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: device.identifier))
            session = opened
            observe(opened, gen)
            try opened.start()
            _ = await waitUntil(15, step: 0.2) { opened.state == .started || opened.state == .stopped }
            if opened.state == .started, session === opened {
                sessionPhase = .on
                say("session started")
                return (opened, false)
            }
            say("The session did not start (\(opened.state)).")
            await closeSession("it did not start", quiet: true)
            return (nil, true)
        } catch {
            if session != nil, sessionGen == gen { dropSession() }
            sessionPhase = .failed(Self.explain(error))
            lastSessionEnd = Date()
            say("session failed: \(Self.explain(error))")
            let e = error as? DeviceSessionError
            return (nil, e == .noEligibleDevice || e == .sessionAlreadyExists)
        }
    }

    private func observe(_ opened: DeviceSession, _ gen: Int) {
        sessionTasks.append(Task { [weak self] in
            for await state in opened.stateStream() {
                guard let self, self.sessionGen == gen else { return }
                self.sessionStateChanged(state)
            }
        })
        sessionTasks.append(Task { [weak self] in
            for await error in opened.errorStream() {
                guard let self, self.sessionGen == gen else { return }
                self.say("session error: \(Self.explain(error))")
            }
        })
    }

    private func sessionStateChanged(_ state: DeviceSessionState) {
        onLog?("session: \(state)")
        switch state {
        case .started:
            if sessionPhase == .paused { say("resumed on the glasses") }
            pauseTimer?.cancel()
            sessionPhase = .on
        case .paused:
            sessionPhase = .paused
            say("Paused on the glasses: tap the side of the glasses once to resume. Closed after 30 s.")
            pauseTimer?.cancel()
            pauseTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled, self.sessionPhase == .paused else { return }
                self.run("closing a paused session") { await self.closeSession("paused for 30 s") }
            }
        case .stopping:
            if !closingSession { sessionPhase = .stopping }
        case .stopped:
            let intended = closingSession
            let link = preferredDevice().map { "\($0.linkState)" } ?? "unknown"
            dropSession()
            if !intended {
                say("The glasses ended the session (link: \(link)). Usually the back gesture, tap-and-hold, or the headset microphone switching on. The next test opens a new one.")
            }
        default:
            break
        }
    }

    /// The session is gone: drop everything that hung off it.
    private func dropSession() {
        sessionGen += 1
        sessionTasks.forEach { $0.cancel() }
        sessionTasks.removeAll()
        pauseTimer?.cancel()
        dropCamera()
        display.dropAll()
        session = nil
        lastSessionEnd = Date()
        sessionPhase = .off
    }

    /// Closes inputs, display, camera and then the session, each confirmed
    /// with a time limit. Afterwards nothing is held, whatever the glasses said.
    func closeSession(_ reason: String, quiet: Bool = false) async {
        guard let current = session else {
            if sessionPhase != .off { sessionPhase = .off }
            return
        }
        closingSession = true
        defer { closingSession = false }
        if !quiet { say("closing the session (\(reason))…") }
        sessionPhase = .stopping
        await display.closeInputs(on: current)
        await display.closeDisplay()
        await closeCamera(escalate: false)
        current.stop()
        let stopped = await waitUntil(3, step: 0.1) { current.state == .stopped }
        if session === current { dropSession() }
        if !quiet { say(stopped ? "session closed" : "session dropped (the glasses did not confirm)") }
    }

    /// Starts over: closes the session, waits, opens a new one.
    func newSession() async -> DeviceSession? {
        await closeSession("starting over")
        return await ensureSession()
    }

    /// A session nobody uses is closed after a minute.
    private func scheduleIdleClose() {
        idleTimer?.cancel()
        guard session != nil else { return }
        idleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, !Task.isCancelled, self.session != nil, !self.sessionInUse,
                  !self.keepSessionOpen, self.busy == nil else { return }
            self.run("closing the unused session") { await self.closeSession("unused for a minute") }
        }
    }

    static func explain(_ error: Error) -> String {
        guard let e = error as? DeviceSessionError else { return "\(error)" }
        switch e {
        case .noEligibleDevice: return "no eligible glasses (not connected, or not registered for this app)"
        case .sessionAlreadyExists: return "a session is already running"
        case .datAppOnTheGlassesUpdateRequired: return "the toolkit app on the glasses needs an update (Meta AI app → glasses → updates)"
        case .thermalCritical, .thermalEmergency: return "the glasses are too hot"
        case .batteryCritical: return "the glasses' battery is too low"
        case .capabilityAlreadyActive: return "the session still holds the old one"
        default: return e.description
        }
    }

    // MARK: Camera (and the glasses' microphone on the camera stream)

    /// hvc1 (default): compressed video, the only kind that fits the Bluetooth
    /// link, and it keeps flowing off screen; shown through `preview`. raw:
    /// uncompressed, needs the Wi-Fi link. mic: the glasses' microphone as
    /// 16 kHz audio on the same stream. ask: may open the Meta AI app for a
    /// permission (not while the phone is locked). Returns once frames flow.
    @discardableResult
    func openCamera(raw: Bool = false, showFrames: Bool = true, mic: Bool = false,
                    ask: Bool = true, resolution: StreamingResolution = .medium) async -> Bool {
        if camera != nil { await closeCamera() }
        say("camera: checking permission…")
        guard await allowed(.camera, ask: ask) else {
            cameraPhase = .failed("no camera permission")
            return false
        }
        var withMic = mic
        if mic, !(await allowed(.microphone, ask: ask)) {
            withMic = false
            say("camera: starting without the microphone (no permission)")
        }
        guard let current = await ensureSession() else {
            cameraPhase = .failed("no session")
            return false
        }
        let config = StreamConfiguration(
            videoCodec: raw ? VideoCodec.raw : VideoCodec.hvc1,
            audioCodec: withMic ? .pcm(sampleRate: .rate16000, numberOfChannels: 1) : nil,
            resolution: resolution,
            frameRate: 24)
        let added: Camera
        do {
            guard let c = try current.addCamera(config: config) else {
                say("camera: the glasses offer no camera on this session")
                cameraPhase = .failed("no camera offered")
                return false
            }
            added = c
        } catch {
            say("camera failed: \(Self.explain(error))")
            cameraPhase = .failed(Self.explain(error))
            if (error as? DeviceSessionError) == .capabilityAlreadyActive {
                await closeSession("the old camera was still attached")
            }
            return false
        }
        cameraGen += 1
        let gen = cameraGen
        camera = added
        streamStarted = false
        frames = 0
        fpsWindow = []
        micFrames = 0
        micLevel = 0
        micRate = 0
        micMeter.reset()
        previewing = false
        frame = nil
        preview.flush()
        self.showFrames = showFrames
        cameraPhase = .starting
        let stream = added.stream
        cameraTokens.append(stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.streamStateChanged(state, gen: gen) }
        })
        cameraTokens.append(stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.streamFailed(error, gen: gen) }
        })
        cameraTokens.append(stream.videoFramePublisher.listen { [weak self] frame in
            let image = raw ? frame.makeUIImage() : nil
            Task { @MainActor in self?.gotFrame(image, video: raw ? nil : frame, gen: gen) }
        })
        cameraTokens.append(stream.photoDataPublisher.listen { [weak self] photo in
            let image = UIImage(data: photo.data)
            Task { @MainActor in self?.gotPhoto(image, gen: gen) }
        })
        if withMic {
            let meter = micMeter
            cameraTokens.append(stream.audioFramePublisher.listen { [weak self] audio in
                let (level, rate) = meter.add(audio.pcmBuffer)
                Task { @MainActor in self?.gotAudio(level: level, rate: rate, gen: gen) }
            })
        }
        stream.start()
        say("camera: starting (\(raw ? "raw" : "hvc1"), \(resolution)\(withMic ? ", glasses mic" : "")); waiting for the glasses")
        _ = await waitUntil(15, step: 0.2) { self.cameraGen != gen || self.cameraPhase == .on }
        guard cameraGen == gen, camera != nil else { return false }
        if cameraPhase == .on {
            cameraRefusals = 0
            updateBanner()
            return true
        }
        say("camera: no picture after 15 s (\(stream.state)); closing it")
        await closeCamera()
        noteCameraRefusal()
        return false
    }

    private func streamStateChanged(_ state: StreamState, gen: Int) {
        guard gen == cameraGen else { return }
        switch state {
        case .streaming:
            streamStarted = true
            if cameraPhase != .on { onLog?("camera: streaming") }
            cameraPhase = .on
        case .paused:
            cameraPhase = .paused
            say("camera: paused on the glasses (tap the side of the glasses once to resume)")
        case .waitingForDevice, .starting:
            streamStarted = true
            onLog?("camera: \(state)")
        case .stopping, .stopped:
            onLog?("camera: \(state)")
            guard streamStarted, !closingCamera else { return }
            say("camera: stopped by the glasses; releasing it")
            run("releasing the camera") { await self.closeCamera() }
        }
    }

    private func streamFailed(_ error: StreamError, gen: Int) {
        guard gen == cameraGen else { return }
        switch error {
        case .thermalHot: say("camera: the glasses are too hot. Let them cool down.")
        case .batteryLow: say("camera: the glasses' battery is too low.")
        case .peakPowerLimit: say("camera: the glasses hit their power limit. Try again in a minute.")
        case .hingesClosed: say("camera: the glasses are folded.")
        case .permissionDenied: say("camera: permission denied in the Meta AI app.")
        default: say("camera error: \(error)")
        }
        switch error {
        case .videoStreamingError, .deviceNotConnected, .timeout: noteCameraRefusal()
        default: break
        }
        guard !closingCamera else { return }
        run("releasing the camera") { await self.closeCamera() }
    }

    private func noteCameraRefusal() {
        cameraRefusals += 1
        if cameraRefusals >= 2 {
            say("The glasses refused the camera \(cameraRefusals) times in a row. Switch the glasses off and on, then tap Reset → Reset glasses connection.")
        }
        updateBanner()
    }

    /// camera.stop() cascades to the stream and the photo capture and detaches
    /// the camera (Meta's CameraAccess sample). Waits for the confirmation; a
    /// camera that doesn't confirm takes the session down with it.
    func closeCamera(escalate: Bool = true) async {
        guard let closing = camera else {
            if cameraPhase != .off { cameraPhase = .off }
            return
        }
        closingCamera = true
        defer { closingCamera = false }
        cameraGen += 1
        camera = nil
        cameraPhase = .stopping
        let tokens = cameraTokens
        cameraTokens = []
        for token in tokens { await token.cancel() }
        closing.stop()
        let stopped = await waitUntil(3, step: 0.1) { closing.state == .stopped }
        resetCameraView()
        cameraPhase = .off
        if stopped {
            say("camera: closed")
        } else if escalate, session != nil {
            say("camera: the glasses did not confirm the stop; closing the session to release it")
            await closeSession("releasing the camera", quiet: true)
        } else {
            say("camera: closed (not confirmed by the glasses)")
        }
    }

    /// The session is gone; so is its camera.
    private func dropCamera() {
        cameraGen += 1
        camera = nil
        cancel(&cameraTokens)
        resetCameraView()
        if cameraPhase != .off { cameraPhase = .off }
    }

    private func resetCameraView() {
        fps = 0
        previewing = false
        preview.flush()
    }

    private func gotFrame(_ image: UIImage?, video: VideoFrame?, gen: Int) {
        guard gen == cameraGen else { return }
        frames += 1
        let now = Date()
        fpsWindow.append(now)
        fpsWindow.removeAll { now.timeIntervalSince($0) > 2 }
        fps = Double(fpsWindow.count) / 2
        if cameraPhase != .on { cameraPhase = .on }
        if showFrames {
            if let image {
                frame = image
            } else if let video {
                preview.show(video.sampleBuffer)
                if !previewing { previewing = true }
            }
        }
        if frames == 1 {
            var size = ""
            if let image {
                size = " (\(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale)))"
            } else if let video, let format = CMSampleBufferGetFormatDescription(video.sampleBuffer) {
                let d = CMVideoFormatDescriptionGetDimensions(format)
                size = " (\(d.width)×\(d.height))"
            }
            say("camera: first frame arrived\(size)")
        }
    }

    private func gotAudio(level: Double, rate: Double, gen: Int) {
        guard gen == cameraGen else { return }
        micFrames += 1
        micLevel = level
        micRate = rate
        if micFrames == 1 { onLog?("glasses mic (toolkit): first audio, \(Int(rate)) Hz") }
    }

    // MARK: Photo

    /// Takes a photo. If the camera wasn't running, it is opened for the photo
    /// and closed again afterwards, so the LED doesn't stay on.
    @discardableResult
    func takePhoto(ask: Bool = true) async -> Bool {
        let openedHere = camera == nil || cameraPhase != .on
        if openedHere {
            guard await openCamera(showFrames: true, ask: ask) else { return false }
        }
        guard let current = camera, cameraPhase == .on else {
            say("photo: the camera is not streaming")
            return false
        }
        let before = photoCount
        photoAskedAt = Date()
        guard current.stream.capturePhoto(format: .jpeg) else {
            say("photo: the glasses refused the request")
            if openedHere { await closeCamera() }
            return false
        }
        say("photo: requested, waiting for the glasses…")
        let got = await waitUntil(12, step: 0.1) { self.photoCount != before }
        if !got { say("photo: nothing arrived within 12 s") }
        if openedHere { await closeCamera() }
        return got
    }

    private func gotPhoto(_ image: UIImage?, gen: Int) {
        guard gen == cameraGen else { return }
        photo = image
        photoCount += 1
        if let asked = photoAskedAt { photoMs = Int(Date().timeIntervalSince(asked) * 1000) }
        // The video layer freezes after a photo unless it is flushed.
        preview.flush()
        say("photo: received\(photoMs.map { " after \($0) ms" } ?? "")\(image == nil ? " but could not decode it" : "")")
    }

    // MARK: Display and inputs

    /// Shows a card. A card shown less than 10 s ago is updated in place.
    /// After that the app may have been closed on the glasses (back gesture),
    /// which only a new session undoes, so a display that was used before is
    /// reopened on a new session. `reopen` forces that.
    @discardableResult
    func showCard(title: String, body: String, reopen: Bool = false) async -> Bool {
        if !reopen, display.isOpen, let at = display.lastCardAt, Date().timeIntervalSince(at) < 10,
           let current = session, current.state == .started {
            let ok = await display.show(on: current, title: title, body: body, fresh: false)
            say(ok ? "display: card updated" : "display: \(display.lastError)")
            return ok
        }
        say("display: opening…")
        guard var target = await ensureSession() else { return false }
        if reopen || display.usedInSession {
            if camera == nil && !display.inputsOpen {
                say("display: reopening on a new session (the only way back after the back gesture)")
                await closeSession("reopening the display", quiet: true)
                guard let fresh = await ensureSession() else { return false }
                target = fresh
            } else {
                onLog?("display: restarting it on the current session (the camera or gestures use it)")
            }
        }
        var ok = await display.show(on: target, title: title, body: body, fresh: true)
        if !ok, display.needsNewSession {
            await closeSession("the display was stuck", quiet: true)
            if let fresh = await ensureSession() {
                ok = await display.show(on: fresh, title: title, body: body, fresh: true)
            }
        }
        say(ok ? "display: card on the lens; pick with the Neural Band or tap Close" : "display: \(display.lastError)")
        return ok
    }

    func closeCard() async {
        await display.closeDisplay()
        say("display: closed")
    }

    /// withCard: gestures from the frame only, the Neural Band stays with a
    /// card on the lens. Otherwise every gesture goes to the phone (the card's
    /// buttons then won't react to the band).
    @discardableResult
    func startInputs(withCard: Bool) async -> Bool {
        say("inputs: opening…")
        guard let first = await ensureSession() else { return false }
        var target = first
        let sources: Set<InputSource> = withCard
            ? [.captouch, .captureButton, .actionButton]
            : [.captouch, .neuralBand, .captureButton, .actionButton, .neuralBandDrag]
        var ok = await display.openInputs(on: target, sources: sources)
        if !ok, display.needsNewSession {
            await closeSession("the inputs were stuck", quiet: true)
            if let fresh = await ensureSession() {
                target = fresh
                ok = await display.openInputs(on: fresh, sources: sources)
            }
        }
        guard ok else {
            say("inputs: \(display.lastError)")
            return false
        }
        if withCard {
            _ = await display.show(on: target, title: "Gesture test",
                                   body: "Tap and swipe on the frame; pick with the Neural Band. Close ends the test.", fresh: true)
        }
        say("inputs: listening\(withCard ? " (frame gestures; the Neural Band works the card)" : " (every gesture)"); try them now")
        return true
    }

    func stopInputs() async {
        if let current = session {
            await display.closeInputs(on: current)
        } else {
            display.dropAll()
        }
        say("inputs: stopped")
    }

    // MARK: Permission

    /// Asks for the toolkit's camera and microphone permissions, one after
    /// the other, while the screen is on: the Meta AI app can't ask once the
    /// phone is locked.
    func preparePermissions() async {
        _ = await allowed(.camera)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        _ = await allowed(.microphone)
    }

    private func allowed(_ permission: Permission, ask: Bool = true) async -> Bool {
        let status: PermissionStatus
        do {
            status = try await wearables.checkPermissionStatus(permission)
        } catch {
            // Not a "no": usually nothing is connected.
            say("\(permission) permission: the glasses aren't answering (\(error))")
            return false
        }
        if status == .granted { return true }
        guard ask else {
            say("\(permission) permission not granted yet. It can only be asked with the screen on: run that test once with the app open.")
            return false
        }
        guard UIApplication.shared.applicationState == .active else {
            say("\(permission) permission can only be asked with the app in front")
            return false
        }
        say("\(permission) permission: asking in the Meta AI app…")
        for attempt in 1...2 {
            do {
                let answer = try await wearables.requestPermission(permission)
                // Back from the Meta AI app: give it a moment, then read the status again.
                _ = await waitUntil(5, step: 0.2) { UIApplication.shared.applicationState == .active }
                try? await Task.sleep(nanoseconds: 800_000_000)
                let now = (try? await wearables.checkPermissionStatus(permission)) ?? answer
                say(now == .granted ? "\(permission) permission: granted"
                    : "\(permission) permission: \(now). Allow it in the Meta AI app → App connections → Stride Lab.")
                return now == .granted
            } catch {
                if (error as? PermissionError) == .requestInProgress, attempt == 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                say("\(permission) permission failed: \(error)")
                return false
            }
        }
        return false
    }

    // MARK: Closing

    /// Closes everything that runs on the glasses; keeps the registration.
    func closeEverything() async {
        if session != nil {
            await closeSession("stop everything")
        } else {
            dropSession()
        }
    }

    /// The app is being closed: release the glasses at once, without waiting
    /// for answers (there is no time for them).
    func shutdownNow() {
        idleTimer?.cancel()
        pauseTimer?.cancel()
        currentWorker?.cancel()
        if let current = session { display.shutdownNow(on: current) }
        camera?.stop()
        session?.stop()
        camera = nil
        session = nil
        cameraPhase = .off
        sessionPhase = .off
    }
}

/// Level of the glasses' microphone audio that arrives on the camera stream.
/// Called on the toolkit's thread.
final class MicMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peakValue: Float = 0

    func reset() { lock.lock(); peakValue = 0; lock.unlock() }

    var peak: Float { lock.lock(); defer { lock.unlock() }; return peakValue }

    func add(_ buffer: AVAudioPCMBuffer) -> (Double, Double) {
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        if let f = buffer.floatChannelData?[0] {
            for i in 0..<n { sum += f[i] * f[i] }
        } else if let s = buffer.int16ChannelData?[0] {
            for i in 0..<n { let v = Float(s[i]) / 32768; sum += v * v }
        }
        let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
        lock.lock(); peakValue = max(peakValue, rms); lock.unlock()
        return (Double(min(1, rms * 6)), buffer.format.sampleRate)
    }
}
