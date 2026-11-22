import Foundation
import UIKit

struct LogLine: Identifiable {
    let id: Int
    let time: String
    let text: String
}

/// Ties the parts together, keeps the log, and runs the screen-off round.
///
/// Sound has two modes, never mixed:
/// - Voice: the headset link (HFP) is up: microphone, speech to text, speech.
/// - Quiet: the headset link is down: the toolkit's microphone on the camera
///   stream can be used.
/// The headset link never changes while a toolkit session is open: on these
/// glasses that ends the session or leaves the microphone silent, and after a
/// few drops and re-links they refuse until switched off and on (Meta,
/// ios#342, ios#375). Switching mode closes the session first. The headset
/// link is released after two minutes unused, never in between.
@MainActor
final class Lab: ObservableObject {
    let audio = Audio()
    let stt = SttClient()
    let glasses = Glasses()
    let results = ResultStore()
    let settings = LabSettings()

    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var screenOffStep = ""
    @Published private(set) var screenOffRunning = false
    @Published var sttHealth = ""
    /// Shown once after the app was closed while something was open.
    @Published var banner: String?

    private var counter = 0
    private var file: FileHandle?
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private var screenOffTask: Task<Void, Never>?
    private var idleAudioTask: Task<Void, Never>?
    private let markerKey = "stride.openAtExit"

    init() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = folder.appendingPathComponent("stride-lab.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        file = try? FileHandle(forWritingTo: url)
        _ = try? file?.seekToEnd()

        audio.onLog = { [weak self] text in Task { @MainActor in self?.log(text) } }
        stt.onLog = { [weak self] text in self?.log(text) }
        glasses.onLog = { [weak self] text in self?.log(text) }
        let stt = self.stt
        audio.onPCM = { pcm in stt.feed(pcm) }

        // Keep a note of what is open, for the next launch if iOS kills the app.
        let changed: () -> Void = { [weak self] in Task { @MainActor in self?.saveMarker() } }
        glasses.resourcesChanged = changed
        glasses.display.resourcesChanged = changed
        audio.onRunningChanged = changed

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("app in background (nothing is closed: the screen-off round needs it)") }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.log("app back in front")
                self?.glasses.refreshDevice()
            }
        }
        center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("phone locked") }
        }
        center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("phone unlocked") }
        }
        // The app is swiped away: release the glasses before iOS ends it.
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdownNow() }
        }

        log("Stride Lab \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") on iOS \(UIDevice.current.systemVersion)")
        if let open = UserDefaults.standard.stringArray(forKey: markerKey), !open.isEmpty {
            let list = open.joined(separator: ", ")
            banner = "Stride Lab was closed while \(list) \(open.count == 1 ? "was" : "were") on. If the white LED on the glasses is still on, tap Stop in the Meta AI app or switch the glasses off and on."
            log("last run ended without closing: \(list)")
            UserDefaults.standard.removeObject(forKey: markerKey)
        }
        startIdleAudioCheck()
    }

    func log(_ text: String) {
        counter += 1
        let line = LogLine(id: counter, time: clock.string(from: Date()), text: text)
        lines.append(line)
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
        try? file?.write(contentsOf: Data("\(line.time) \(text)\n".utf8))
    }

    /// stridelab://config… from the PC, or the Meta AI app's callback.
    func open(_ url: URL) {
        if settings.apply(configURL: url) {
            log("settings received: STT server \(URL(string: settings.sttURL)?.host ?? "?"), key \(settings.hasKey ? "saved" : "missing")")
            checkStt()
        } else {
            glasses.handle(url)
        }
    }

    // MARK: Sound modes

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Voice: the headset link up. Brought up only with no session open.
    @discardableResult
    func ensureVoice() async -> Bool {
        if audio.running {
            audio.touch()
            return true
        }
        if glasses.hasSession {
            log("sound: closing the glasses session before the headset microphone comes on (it would end the session)")
            await glasses.closeSession("switching the headset microphone on", quiet: true)
            await wait(2)
        }
        let ok = await audio.startAsync()
        if ok { await wait(1.5) }  // let the Bluetooth route settle before a session opens
        return ok
    }

    /// Quiet: the headset link down. Taken down only with no session open.
    func ensureQuiet() async {
        guard audio.running else { return }
        stt.stop()
        if glasses.hasSession {
            log("sound: closing the glasses session before the headset microphone goes off")
            await glasses.closeSession("switching the headset microphone off", quiet: true)
            await wait(2)
        }
        audio.stop()
        await wait(1.5)
    }

    /// Releases the headset link after two minutes unused, when nothing needs it.
    private func startIdleAudioCheck() {
        idleAudioTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                if self.audio.running, !self.glasses.hasSession, !self.stt.isOn, !self.screenOffRunning,
                   self.glasses.busy == nil, self.audio.idleSeconds > 120 {
                    self.audio.stop()
                    self.log("headset microphone released (unused for 2 minutes)")
                }
            }
        }
    }

    // MARK: Test actions (every one goes through the glasses' action queue)

    func micStart() {
        glasses.run("starting the headset microphone") {
            if await self.ensureVoice() { self.audio.resetPeak() }
        }
    }

    func micOff() {
        glasses.run("turning the headset microphone off") { await self.ensureQuiet() }
    }

    func toolkitMicStart() {
        glasses.run("starting the toolkit microphone", timeout: 45) {
            await self.ensureQuiet()
            await self.glasses.openCamera(showFrames: false, mic: true)
        }
    }

    func toolkitMicStop() {
        glasses.run("stopping the toolkit microphone") { await self.glasses.closeCamera() }
    }

    var sttReady: Bool { !settings.sttURL.isEmpty && settings.hasKey }

    func checkStt() {
        guard let key = settings.sttKey, !settings.sttURL.isEmpty else { sttHealth = "address or key missing"; return }
        sttHealth = "checking…"
        SttClient.health(base: settings.sttURL, key: key) { [weak self] text, _ in self?.sttHealth = text }
    }

    func sttStart() {
        guard let key = settings.sttKey, !settings.sttURL.isEmpty else { log("STT: set the server address and key first"); return }
        glasses.run("starting speech to text") {
            guard await self.ensureVoice() else { return }
            self.audio.touch()
            self.stt.start(base: self.settings.sttURL, key: key)
        }
    }

    func sttStop() {
        stt.stop()
        log("speech to text: stream closed")
    }

    /// While a camera stream runs the glasses mute app sound (Meta, ios#358),
    /// so the camera is closed first.
    func speakTest() {
        glasses.run("speaking") {
            if self.glasses.cameraOpen {
                await self.glasses.closeCamera()
                self.log("camera closed first: the glasses mute app sound while it runs")
            }
            guard await self.ensureVoice() else { return }
            self.audio.say("Hello from Stride Lab. You should hear this in your glasses, not from the phone.")
        }
    }

    func beepTest() {
        glasses.run("beeping") {
            if self.glasses.cameraOpen { await self.glasses.closeCamera() }
            guard await self.ensureVoice() else { return }
            self.audio.beep()
        }
    }

    func cameraStart(raw: Bool = false) {
        glasses.run("starting the camera", timeout: 45) { await self.glasses.openCamera(raw: raw) }
    }

    func cameraStop() {
        glasses.run("stopping the camera") { await self.glasses.closeCamera() }
    }

    func photo() {
        glasses.run("taking a photo", timeout: 50) { await self.glasses.takePhoto() }
    }

    func showCard(title: String, body: String, reopen: Bool = false) {
        glasses.run(reopen ? "reopening the card" : "showing a card", timeout: 50) {
            await self.glasses.showCard(title: title, body: body, reopen: reopen)
        }
    }

    func closeCard() {
        glasses.run("closing the card") { await self.glasses.closeCard() }
    }

    func gesturesStart(withCard: Bool) {
        glasses.run("starting gestures", timeout: 50) {
            self.glasses.display.clearInputs()
            self.audio.clearMediaKeys()
            await self.glasses.startInputs(withCard: withCard)
        }
    }

    func gesturesStop() {
        glasses.run("stopping gestures") {
            await self.glasses.stopInputs()
            if self.glasses.display.isOpen { await self.glasses.closeCard() }
        }
    }

    func openSession() {
        glasses.run("opening a session", timeout: 40) { _ = await self.glasses.ensureSession() }
    }

    func newSession() {
        glasses.run("starting a new session", timeout: 45) { _ = await self.glasses.newSession() }
    }

    func closeSession() {
        glasses.run("closing the session") { await self.glasses.closeSession("closed from test 1") }
    }

    /// Leaving a test stops what it started. The session stays for the next one.
    func leave(_ test: TestID) {
        guard !screenOffRunning else { return }
        switch test {
        case .connect:
            break
        case .mic, .camera, .photo:
            if glasses.cameraOpen {
                glasses.run("leaving \(test.title)") {
                    await self.glasses.closeCamera()
                    self.log("left \(test.title): camera closed")
                }
            }
        case .stt:
            if stt.isOn {
                stt.stop()
                log("left \(test.title): speech to text closed")
            }
        case .speech:
            audio.stopSpeaking()
        case .display:
            if glasses.display.isOpen {
                glasses.run("leaving \(test.title)") {
                    await self.glasses.closeCard()
                    self.log("left \(test.title): card closed")
                }
            }
        case .gestures:
            if glasses.display.inputsOpen || glasses.display.isOpen {
                glasses.run("leaving \(test.title)") {
                    await self.glasses.stopInputs()
                    if self.glasses.display.isOpen { await self.glasses.closeCard() }
                    self.log("left \(test.title): gestures stopped")
                }
            }
        }
    }

    // MARK: Resets

    /// Closes everything, keeps the registration.
    func stopEverything() {
        cancelRoundQuietly()
        glasses.run("stopping everything", preempt: true) { await self.stopEverythingNow(quiet: false) }
    }

    func stopEverythingNow(quiet: Bool) async {
        stt.stop()
        audio.stopSpeaking()
        await glasses.closeEverything()
        if audio.running {
            await wait(0.5)
            audio.stop()
        }
        if !quiet { glasses.say("Everything is closed. The registration is kept.") }
    }

    func resetGlassesConnection() {
        cancelRoundQuietly()
        glasses.run("resetting the glasses connection", timeout: 45, preempt: true) {
            await self.glasses.closeEverything()
            self.glasses.clearStatus()
            await self.wait(2)
            let opened = await self.glasses.ensureSession()
            let detail = self.glasses.status
            self.glasses.say(opened != nil ? "Glasses connection reset: session started." : "Glasses connection reset failed: \(detail)")
        }
    }

    func resetAudio() {
        cancelRoundQuietly()
        glasses.run("resetting the sound", preempt: true) {
            self.stt.stop()
            if self.glasses.hasSession { await self.glasses.closeSession("resetting the sound", quiet: true) }
            self.audio.stop()
            await self.wait(1.5)
            self.glasses.say("Sound reset. It comes back on when a test needs it.")
        }
    }

    func fullReset() {
        cancelRoundQuietly()
        glasses.run("full reset", timeout: 45, preempt: true) {
            await self.stopEverythingNow(quiet: true)
            self.stt.clear()
            self.glasses.display.clearChoices()
            self.glasses.display.clearInputs()
            self.audio.clearMediaKeys()
            self.glasses.clearStatus()
            self.banner = nil
            self.glasses.say("Full reset done. The registration is kept.")
        }
    }

    private func cancelRoundQuietly() {
        guard screenOffRunning else { return }
        screenOffTask?.cancel()
        screenOffRunning = false
        screenOffStep = "stopped"
        log("screen off: stopped")
    }

    // MARK: Closing the app

    /// Releases the glasses synchronously: there is no time to wait for answers.
    func shutdownNow() {
        log("app closing: releasing the glasses")
        screenOffTask?.cancel()
        idleAudioTask?.cancel()
        stt.stop()
        glasses.shutdownNow()
        audio.stop()
        UserDefaults.standard.removeObject(forKey: markerKey)
        try? file?.synchronize()
    }

    private func saveMarker() {
        var open: [String] = []
        if glasses.hasSession { open.append("the glasses session") }
        if glasses.cameraOpen { open.append("the camera") }
        if glasses.display.isOpen { open.append("a card on the lens") }
        if glasses.display.inputsOpen { open.append("gestures") }
        if audio.running { open.append("the headset microphone") }
        if open.isEmpty {
            UserDefaults.standard.removeObject(forKey: markerKey)
        } else {
            UserDefaults.standard.set(open, forKey: markerKey)
        }
    }

    // MARK: Screen-off round

    var phoneLocked: Bool { !UIApplication.shared.isProtectedDataAvailable }
    var background: Bool { UIApplication.shared.applicationState != .active }

    private func whereAmI() -> String {
        phoneLocked ? "phone locked" : (background ? "app in background" : "screen on, app in front")
    }

    func startScreenOffRound() {
        guard !screenOffRunning, glasses.busy == nil else { return }
        screenOffRunning = true
        screenOffTask = Task {
            await runScreenOff()
            if !Task.isCancelled {
                await stopEverythingNow(quiet: true)
                log("screen off: finished, everything closed")
            }
            screenOffRunning = false
            screenOffStep = ""
        }
    }

    func cancelScreenOffRound() {
        cancelRoundQuietly()
        glasses.run("stopping the round", preempt: true) {
            await self.stopEverythingNow(quiet: true)
            self.glasses.say("Screen-off round stopped; everything is closed.")
        }
    }

    private func step(_ text: String) {
        screenOffStep = text
        log("screen off: \(text)")
    }

    /// Speak, and wait until the speech has finished.
    private func speak(_ text: String) async {
        audio.say(text)
        await wait(0.4)
        for _ in 0..<80 where audio.speaking { await wait(0.25) }
        await wait(0.3)
    }

    private func waitForChoice(after count: Int, seconds: Double) async -> String? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !Task.isCancelled {
            if glasses.display.choices.count > count { return glasses.display.choices.last }
            await wait(0.25)
        }
        return nil
    }

    /// Order: everything that needs sound first, the camera last, because the
    /// glasses mute app sound while a camera stream runs (Meta, ios#358).
    private func runScreenOff() async {
        let round = Round.screenOff
        glasses.keepSessionOpen = true
        defer { glasses.keepSessionOpen = false }

        step("getting ready: closing everything")
        await stopEverythingNow(quiet: true)
        step("permissions")
        await glasses.preparePermissions()
        if Task.isCancelled { return }
        step("sound on")
        guard await ensureVoice() else { step("the sound could not start"); return }

        step("lock the phone")
        await speak("Screen off round. Lock your phone now and put it in your pocket. I start in ten seconds.")
        await wait(10)
        if Task.isCancelled { return }
        log("screen off: start state: \(whereAmI())")
        if !phoneLocked && !background {
            await speak("The screen still seems to be on. I continue anyway.")
        }

        // 1. Microphone
        step("microphone")
        audio.resetPeak()
        await speak("Microphone test. After the beep, talk for five seconds.")
        audio.beep()
        await wait(5)
        let peak = audio.currentPeak
        let blocks = audio.blocksSinceReset
        results.measure(.mic, round, "input \(audio.input), \(Int(audio.sampleRate)) Hz, peak \(String(format: "%.3f", peak)), \(blocks) audio blocks in 5 s, \(whereAmI())")
        results.set(.mic, round, peak > 0.01 ? (audio.viaGlasses ? .works : .partly) : .fails)
        if Task.isCancelled { return }

        // 2. Speech to text on your server
        step("speech to text")
        if let key = settings.sttKey, !settings.sttURL.isEmpty {
            stt.clear()
            stt.start(base: settings.sttURL, key: key)
            await speak("Speech to text. After the beep, say: the quick brown fox jumps over the lazy dog.")
            audio.beep()
            await wait(8)
            let heard = stt.finals.joined(separator: " ")
            let streamState = stt.state
            let partial = stt.partial
            stt.stop()
            results.measure(.stt, round, heard.isEmpty
                ? "nothing heard (stream: \(streamState)\(partial.isEmpty ? "" : ", partial “\(partial)”")), \(whereAmI())"
                : "heard “\(heard)”, server \(stt.lastLatencyMs ?? -1) ms, \(whereAmI())")
            results.set(.stt, round, heard.isEmpty ? .fails : .works)
            await speak(heard.isEmpty ? "I heard nothing." : "I heard: \(heard)")
        } else {
            results.measure(.stt, round, "skipped: no server address or key")
            await speak("Speech to text skipped, no server set.")
        }
        if Task.isCancelled { return }

        // 3. Card on the lens, answered by ear
        step("display and speech")
        var before = glasses.display.choices.count
        let shown = await glasses.showCard(title: "Screen off test", body: "Did you hear me clearly? Pick Yes or No.")
        await speak("Display test. If you hear this clearly, pick Yes on the display of your glasses. Otherwise pick No.")
        let choice = await waitForChoice(after: before, seconds: 20)
        results.measure(.display, round, shown ? "card shown in \(glasses.display.sendMs ?? -1) ms, answer \(choice ?? "none"), \(whereAmI())" : "no card: \(glasses.status)")
        results.set(.display, round, choice != nil ? .works : .fails)
        if let choice {
            results.measure(.speech, round, "before the camera: you answered \(choice)")
            results.set(.speech, round, choice == "Yes" ? .works : .partly)
        }
        await glasses.closeCard()
        if Task.isCancelled { return }

        // 4. Gestures
        step("gestures")
        await speak("Gesture test. After the beep, for ten seconds: tap and swipe on the side of the glasses, and pinch and swipe with the Neural Band.")
        audio.beep()
        glasses.display.clearInputs()
        audio.clearMediaKeys()
        let listening = await glasses.startInputs(withCard: false)
        await wait(10)
        let inputs = glasses.display.inputs
        let drags = glasses.display.drags
        let keys = audio.mediaKeys
        await glasses.stopInputs()
        let kinds = Set(inputs.map { $0.components(separatedBy: " (").first ?? $0 }).sorted().joined(separator: ", ")
        results.measure(.gestures, round, listening
            ? "glasses inputs: \(inputs.count) (\(kinds)), drags \(drags); media buttons: \(keys.isEmpty ? "none" : keys.joined(separator: ", ")), \(whereAmI())"
            : "no inputs: \(glasses.status)")
        results.set(.gestures, round, inputs.count + drags + keys.count > 0 ? .works : .fails)
        if Task.isCancelled { return }

        // 5. Camera and photo (the glasses may mute my voice meanwhile)
        step("camera and photo")
        await speak("Camera test. The glasses may mute my voice while the camera runs. Look around for eight seconds, then hold still for a photo.")
        let streaming = await glasses.openCamera(showFrames: false, ask: false, resolution: .low)
        await wait(8)
        let frames = glasses.frames
        let cameraState = glasses.cameraPhase.label
        results.measure(.camera, round, streaming ? "\(frames) frames in 8 s (hvc1, low), \(whereAmI())" : "no picture: \(glasses.status), \(whereAmI())")
        results.set(.camera, round, frames > 20 ? .works : (frames > 0 ? .partly : .fails))
        var photoOK = false
        if streaming, !Task.isCancelled {
            photoOK = await glasses.takePhoto(ask: false)
        }
        results.measure(.photo, round, photoOK ? "photo after \(glasses.photoMs ?? -1) ms, \(whereAmI())" : "no photo (camera \(cameraState); \(glasses.status)), \(whereAmI())")
        results.set(.photo, round, photoOK ? .works : .fails)
        await glasses.closeCamera()
        if Task.isCancelled { return }

        // 6. Does sound come back after the camera? (open glasses bug, ios#256)
        step("sound after the camera")
        await wait(2)
        before = glasses.display.choices.count
        _ = await glasses.showCard(title: "Can you hear me?", body: "Pick Yes if you hear my voice again now that the camera is off.")
        await speak("The camera is off. If you can hear me, pick Yes on the display.")
        let after = await waitForChoice(after: before, seconds: 20)
        results.measure(.speech, round, "after the camera: \(after.map { "you answered \($0)" } ?? "no answer"), \(whereAmI())")
        if after == nil || after == "No" { results.set(.speech, round, .partly) }
        if Task.isCancelled { return }

        step("done")
        _ = await glasses.showCard(title: "Stride Lab", body: "Screen-off round done. Unlock your phone to see the results.")
        await speak("Done. Unlock your phone to see the results.")
        audio.beep(660)
        await wait(3)
    }
}
