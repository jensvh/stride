import AVFoundation
import CoreMedia
import Foundation
import MWDATCamera
import MWDATCore
import UIKit

/// Everything that goes through Meta's Device Access Toolkit: registration with
/// the Meta AI app, the device session, camera frames, photos, and the glasses'
/// microphone carried on the camera stream. The display and inputs live in
/// GlassesDisplay.swift (their type names clash with SwiftUI).
///
/// Follows Meta's own sample app (BirdSpotter) on three points that matter:
/// - the session is opened on a named pair of glasses (SpecificDeviceSelector).
///   AutoDeviceSelector picks its device asynchronously, so one made at the
///   moment of a tap is still empty and the session fails with noEligibleDevice;
/// - `started` only means the session exists. The camera waits for the glasses;
///   the display and inputs do not, so they are retried until they attach;
/// - a raw (uncompressed) stream pauses when the app leaves the screen, an HEVC
///   one keeps flowing, so the screen-off round streams HEVC.
@MainActor
final class Glasses: ObservableObject {
    @Published private(set) var registration = "unknown"
    @Published private(set) var registered = false
    @Published private(set) var devices = 0
    @Published private(set) var deviceInfo = "no glasses listed"
    @Published private(set) var connected = false
    @Published private(set) var sessionState = "no session"
    @Published private(set) var status = ""
    @Published private(set) var cameraState = "off"
    @Published private(set) var frame: UIImage?
    @Published private(set) var frames = 0
    @Published private(set) var fps: Double = 0
    @Published private(set) var photo: UIImage?
    @Published private(set) var photoMs: Int?
    @Published private(set) var micFrames = 0
    @Published private(set) var micLevel: Double = 0
    @Published private(set) var micRate: Double = 0
    /// HEVC frames are shown on `preview`; raw ones as `frame`.
    @Published private(set) var previewing = false
    let preview = FramePreview()

    var onLog: ((String) -> Void)?
    let display = GlassesDisplay()

    private let wearables = Wearables.shared
    private var session: DeviceSession?
    private var opening: Task<DeviceSession?, Never>?
    private var sessionTasks: [Task<Void, Never>] = []
    private var camera: Camera?
    private var deviceTokens: [any AnyListenerToken] = []
    private var cameraTokens: [any AnyListenerToken] = []
    private var fpsWindow: [Date] = []
    private var photoAskedAt: Date?
    private var showFrames = true
    private let micMeter = MicMeter()

    init() {
        display.onLog = { [weak self] text in self?.onLog?(text) }
        Task { [weak self] in
            guard let self else { return }
            for await state in self.wearables.registrationStateStream() {
                self.registration = String(describing: state)
                self.registered = state == .registered
                self.onLog?("registration: \(state)")
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

    /// Something every glasses test shows under its buttons, so a button never
    /// does "nothing": it says what it is doing or why it stopped.
    private func say(_ text: String) {
        status = text
        onLog?(text)
    }

    // MARK: Devices

    /// The link, compatibility and wear state fill in after a device is listed,
    /// so each one is watched rather than read once.
    private func watchDevices(_ ids: [DeviceIdentifier]) {
        cancel(&deviceTokens)
        let found = ids.compactMap { wearables.deviceForIdentifier($0) }
        for device in found {
            deviceTokens.append(device.addLinkStateListener { [weak self] _ in Task { @MainActor in self?.refreshDevice() } })
            deviceTokens.append(device.addCompatibilityListener { [weak self] _ in Task { @MainActor in self?.refreshDevice() } })
            deviceTokens.append(device.addDeviceStateListener { [weak self] _ in Task { @MainActor in self?.refreshDevice() } })
        }
        refreshDevice()
    }

    private func refreshDevice() {
        guard let device = preferredDevice() else {
            deviceInfo = "no glasses listed"
            connected = false
            return
        }
        connected = device.linkState == .connected
        let name = device.name.isEmpty ? "glasses" : device.name
        let info = "\(name): \(device.linkState), \(device.compatibility().displayString), \(device.donState)"
            + (device.supportsDisplay() ? ", has display" : ", no display")
            + (device.batteryLevel.map { $0 > 0 ? ", battery \($0)%" : "" } ?? "")
        if info != deviceInfo {
            deviceInfo = info
            onLog?("glasses: \(info)")
        }
    }

    /// Worn and connected first, then connected, then compatible: the pair on
    /// your face is the one to open a session on.
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

    // MARK: Registration

    func register() {
        Task {
            do {
                try await wearables.startRegistration()
                say("registration started: confirm in the Meta AI app")
            } catch {
                say("registration failed: \(error)")
            }
        }
    }

    func unregister() {
        Task {
            do { try await wearables.startUnregistration() } catch { say("unregister failed: \(error)") }
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

    /// One session per app run; camera, display and inputs hang off it.
    /// Concurrent callers share the same attempt.
    func ensureSession() async -> DeviceSession? {
        if let session, session.state == .started { return session }
        if let opening { return await opening.value }
        let attempt = Task { await openSession() }
        opening = attempt
        let result = await attempt.value
        opening = nil
        return result
    }

    private func openSession() async -> DeviceSession? {
        if let session {
            session.stop()
            self.session = nil
            sessionTasks.forEach { $0.cancel() }
            sessionTasks.removeAll()
        }
        guard registered else {
            say("Not registered: tap Register with the Meta AI app in test 1 first.")
            return nil
        }
        // A device listed at launch gets its link a moment later: give it 5 s.
        var device = preferredDevice()
        for _ in 0..<20 where device?.linkState != .connected {
            try? await Task.sleep(nanoseconds: 250_000_000)
            device = preferredDevice()
        }
        guard let device else {
            say("No glasses listed. Check the glasses are paired in the Meta AI app.")
            return nil
        }
        if device.linkState != .connected {
            say("The glasses are not connected (\(device.linkState)). Open the Meta AI app, check the glasses show as connected, then try again.")
            return nil
        }
        switch device.compatibility() {
        case .deviceUpdateRequired: say("The glasses need a firmware update (Meta AI app → glasses settings)."); return nil
        case .sdkUpdateRequired: say("These glasses need a newer toolkit version in Stride Lab."); return nil
        default: break
        }
        say("opening a session on \(device.name.isEmpty ? "the glasses" : device.name)…")
        do {
            let session = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: device.identifier))
            self.session = session
            sessionTasks.append(Task { [weak self] in
                for await state in session.stateStream() {
                    self?.sessionState = String(describing: state)
                    self?.onLog?("session: \(state)")
                    if state == .stopped { self?.sessionEnded(session) }
                }
            })
            sessionTasks.append(Task { [weak self] in
                for await error in session.errorStream() {
                    self?.say("session error: \(Self.explain(error))")
                }
            })
            try session.start()
            for _ in 0..<60 where session.state != .started {
                if session.state == .stopped { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard session.state == .started else {
                say("The session did not start (\(session.state)). Keep the glasses on and connected, then try again.")
                return nil
            }
            say("session started")
            return session
        } catch {
            say("session failed: \(Self.explain(error))")
            return nil
        }
    }

    private static func explain(_ error: Error) -> String {
        guard let e = error as? DeviceSessionError else { return "\(error)" }
        switch e {
        case .noEligibleDevice: return "no eligible glasses (not connected, or not registered for this app)"
        case .datAppOnTheGlassesUpdateRequired: return "the toolkit app on the glasses needs an update (Meta AI app → glasses → updates)"
        case .thermalCritical, .thermalEmergency: return "the glasses are too hot"
        case .batteryCritical: return "the glasses' battery is too low"
        default: return e.description
        }
    }

    /// The glasses ended the session (or it failed): its camera, display and
    /// inputs are gone with it, so the next test opens a fresh one.
    private func sessionEnded(_ ended: DeviceSession) {
        guard session === ended else { return }
        stopCamera()
        display.stop()
        session = nil
        say("The glasses ended the session. The next test opens a new one.")
    }

    func endSession() {
        stopCamera()
        display.stop()
        session?.stop()
        session = nil
        sessionTasks.forEach { $0.cancel() }
        sessionTasks.removeAll()
        sessionState = "no session"
    }

    // MARK: Camera (and the glasses' microphone on the camera stream)

    /// hvc1 (default): compressed video, the only kind that fits the Bluetooth
    /// link, and it keeps flowing when the app leaves the screen. Shown through
    /// `preview` (the toolkit can't make a UIImage from it). raw: uncompressed,
    /// needs the faster Wi-Fi link and pauses off screen. mic: the glasses'
    /// microphone as 16 kHz audio on the same stream. ask: may open the Meta AI
    /// app for a permission (not while the phone is locked: it can't show it).
    func startCamera(raw: Bool = false, showFrames: Bool = true, mic: Bool = false) {
        Task { await startCameraNow(raw: raw, showFrames: showFrames, mic: mic) }
    }

    @discardableResult
    func startCameraNow(raw: Bool = false, showFrames: Bool = true, mic: Bool = false,
                        ask: Bool = true, resolution: StreamingResolution = .medium) async -> Bool {
        say("camera: checking permission…")
        guard await allowed(.camera, ask: ask) else { return false }
        var withMic = mic
        if mic, !(await allowed(.microphone, ask: ask)) { withMic = false }
        guard let session = await ensureSession() else { return false }
        stopCamera()
        self.showFrames = showFrames
        let config = StreamConfiguration(
            videoCodec: raw ? VideoCodec.raw : VideoCodec.hvc1,
            audioCodec: withMic ? .pcm(sampleRate: .rate16000, numberOfChannels: 1) : nil,
            resolution: resolution,
            frameRate: 24)
        do {
            guard let camera = try session.addCamera(config: config) else {
                say("camera: the glasses offer no camera on this session")
                return false
            }
            self.camera = camera
            frames = 0
            fpsWindow = []
            micFrames = 0
            micLevel = 0
            micMeter.reset()
            previewing = false
            frame = nil
            preview.flush()
            let stream = camera.stream
            cameraTokens.append(stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    self?.cameraState = String(describing: state)
                    self?.onLog?("camera: \(state)")
                }
            })
            cameraTokens.append(stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.say("camera error: \(error)") }
            })
            cameraTokens.append(stream.videoFramePublisher.listen { [weak self] frame in
                let image = raw ? frame.makeUIImage() : nil
                Task { @MainActor in self?.gotFrame(image, video: raw ? nil : frame) }
            })
            cameraTokens.append(stream.photoDataPublisher.listen { [weak self] photo in
                let image = UIImage(data: photo.data)
                Task { @MainActor in self?.gotPhoto(image) }
            })
            if withMic {
                let meter = micMeter
                cameraTokens.append(stream.audioFramePublisher.listen { [weak self] audio in
                    let (level, rate) = meter.add(audio.pcmBuffer)
                    Task { @MainActor in self?.gotAudio(level: level, rate: rate) }
                })
            }
            cameraState = "starting"
            stream.start()
            say("camera: starting (\(raw ? "raw" : "hvc1"), \(resolution)\(withMic ? ", glasses mic" : ""); waiting for the glasses)")
            return true
        } catch {
            say("camera failed: \(Self.explain(error))")
            return false
        }
    }

    func stopCamera() {
        camera?.stream.stop()
        camera?.stop()
        camera = nil
        cancel(&cameraTokens)
        if cameraState != "off" { cameraState = "off" }
        fps = 0
    }

    /// Listener tokens stop their listener only when cancelled.
    private func cancel(_ tokens: inout [any AnyListenerToken]) {
        let old = tokens
        tokens = []
        Task { for token in old { await token.cancel() } }
    }

    var cameraStreaming: Bool { cameraState == "streaming" }
    var micPeak: Float { micMeter.peak }

    private func gotFrame(_ image: UIImage?, video: VideoFrame?) {
        frames += 1
        let now = Date()
        fpsWindow.append(now)
        fpsWindow.removeAll { now.timeIntervalSince($0) > 2 }
        fps = Double(fpsWindow.count) / 2
        if showFrames {
            if let image { frame = image }
            else if let video {
                preview.show(video.sampleBuffer)
                if !previewing { previewing = true }
            }
        }
        if frames == 1 {
            var size = ""
            if let image { size = " (\(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale)))" }
            else if let video, let format = CMSampleBufferGetFormatDescription(video.sampleBuffer) {
                let d = CMVideoFormatDescriptionGetDimensions(format)
                size = " (\(d.width)×\(d.height))"
            }
            say("camera: first frame arrived\(size)")
        }
    }

    private func gotAudio(level: Double, rate: Double) {
        micFrames += 1
        micLevel = level
        micRate = rate
        if micFrames == 1 { onLog?("glasses mic (toolkit): first audio, \(Int(rate)) Hz") }
    }

    // MARK: Photo

    func takePhoto(raw: Bool = false, ask: Bool = true) {
        Task {
            if camera == nil || !cameraStreaming {
                guard await startCameraNow(raw: raw, showFrames: true, ask: ask) else { return }
                for _ in 0..<60 where !cameraStreaming {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            guard let camera, cameraStreaming else {
                say("photo: the camera did not start streaming (\(cameraState))")
                return
            }
            photoAskedAt = Date()
            let ok = camera.stream.capturePhoto(format: .jpeg)
            say(ok ? "photo: requested, waiting for the glasses…" : "photo: the glasses refused the request")
        }
    }

    private func gotPhoto(_ image: UIImage?) {
        photo = image
        // The video layer freezes after a photo unless it is flushed.
        preview.flush()
        if let asked = photoAskedAt { photoMs = Int(Date().timeIntervalSince(asked) * 1000) }
        say("photo: received\(photoMs.map { " after \($0) ms" } ?? "")\(image == nil ? " but could not decode it" : "")")
    }

    // MARK: Display and inputs

    func showCard(title: String, body: String) {
        Task {
            say("display: opening…")
            guard let session = await ensureSession() else { return }
            if let device = session.device, !device.supportsDisplay() {
                say("display: these glasses report no display")
                return
            }
            var ok = await display.show(on: session, title: title, body: body)
            if !ok, display.needsNewSession, let fresh = await newSession() {
                ok = await display.show(on: fresh, title: title, body: body)
            }
            say(ok ? "display: card shown, pick on the lens" : "display: \(display.lastError)")
        }
    }

    /// card: also show a card on the lens while listening, so this app is the
    /// one in front on the glasses.
    func startInputs(card: Bool = false) {
        Task {
            say("inputs: opening…")
            guard var session = await ensureSession() else { return }
            var ok = await display.startInputs(on: session)
            if !ok, display.needsNewSession, let fresh = await newSession() {
                session = fresh
                ok = await display.startInputs(on: fresh)
            }
            guard ok else { say("inputs: \(display.lastError)"); return }
            if card {
                _ = await display.show(on: session, title: "Gesture test", body: "Swipe, tap and pinch. Every gesture shows up on the phone.")
            }
            say("inputs: listening\(card ? " with a card on the lens" : ""), tap or pinch now")
        }
    }

    /// Ends the current session and opens a new one.
    func newSession() async -> DeviceSession? {
        onLog?("session: starting over")
        endSession()
        try? await Task.sleep(nanoseconds: 500_000_000)
        return await ensureSession()
    }

    // MARK: Permission

    /// Asks for the toolkit's camera and microphone permissions while the
    /// screen is on: the Meta AI app can't ask once the phone is locked.
    func preparePermissions() async {
        _ = await allowed(.camera)
        _ = await allowed(.microphone)
    }

    private func allowed(_ permission: Permission, ask: Bool = true) async -> Bool {
        do {
            if try await wearables.checkPermissionStatus(permission) == .granted { return true }
            guard ask else {
                say("\(permission) permission not granted yet (it can only be asked with the screen on)")
                return false
            }
            say("\(permission) permission: asking in the Meta AI app")
            let status = try await wearables.requestPermission(permission)
            if status != .granted { say("\(permission) permission: \(status). Allow it in the Meta AI app → App connections → Stride Lab.") }
            return status == .granted
        } catch {
            say("\(permission) permission failed: \(error)")
            return false
        }
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
