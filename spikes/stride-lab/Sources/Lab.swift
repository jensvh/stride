import Foundation
import UIKit

struct LogLine: Identifiable {
    let id: Int
    let time: String
    let text: String
}

/// Ties the parts together, keeps the log, and runs the screen-off round: a
/// fixed sequence narrated through the glasses, because you can't see the phone.
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

    private var counter = 0
    private var file: FileHandle?
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private var screenOffTask: Task<Void, Never>?

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

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("app in background") }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("app back in front") }
        }
        center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("phone locked") }
        }
        center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("phone unlocked") }
        }
        log("Stride Lab \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") on iOS \(UIDevice.current.systemVersion)")
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

    // MARK: STT

    var sttReady: Bool { !settings.sttURL.isEmpty && settings.hasKey }

    func checkStt() {
        guard let key = settings.sttKey, !settings.sttURL.isEmpty else { sttHealth = "address or key missing"; return }
        sttHealth = "checking…"
        SttClient.health(base: settings.sttURL, key: key) { [weak self] text, _ in self?.sttHealth = text }
    }

    func startStt() {
        guard let key = settings.sttKey, !settings.sttURL.isEmpty else { log("STT: set the server address and key first"); return }
        audio.start { [weak self] ok in
            guard ok, let self else { return }
            self.stt.start(base: self.settings.sttURL, key: key)
        }
    }

    // MARK: Screen-off round

    var locked: Bool { !UIApplication.shared.isProtectedDataAvailable }
    var background: Bool { UIApplication.shared.applicationState != .active }

    private func whereAmI() -> String {
        locked ? "phone locked" : (background ? "app in background" : "screen on, app in front")
    }

    func startScreenOffRound() {
        guard !screenOffRunning else { return }
        screenOffRunning = true
        screenOffTask = Task { await runScreenOff(); screenOffRunning = false; screenOffStep = "" }
    }

    func cancelScreenOffRound() {
        screenOffTask?.cancel()
        screenOffRunning = false
        screenOffStep = "stopped"
        audio.say("Screen off round stopped.")
    }

    private func step(_ text: String) {
        screenOffStep = text
        log("screen off: \(text)")
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Speak, and wait until the speech has finished.
    private func speak(_ text: String) async {
        audio.say(text)
        await wait(0.4)
        for _ in 0..<60 where audio.speaking { await wait(0.25) }
        await wait(0.3)
    }

    private func runScreenOff() async {
        let round = Round.screenOff
        // The Meta AI app can only ask for permissions with the screen on.
        step("permissions")
        await glasses.preparePermissions()
        let ok = await withCheckedContinuation { c in audio.start { c.resume(returning: $0) } }
        guard ok else { step("audio could not start"); return }

        step("lock the phone")
        await speak("Screen off round. Lock your phone now and put it in your pocket. I start in ten seconds.")
        await wait(10)
        if Task.isCancelled { return }
        log("screen off: start state: \(whereAmI())")
        if !locked && !background {
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
        let micOK = peak > 0.01 && audio.sampleRate > 0
        results.measure(.mic, round, "input \(audio.input), \(Int(audio.sampleRate)) Hz, peak \(String(format: "%.3f", peak)), \(blocks) audio blocks in 5 s (about 150 expected), engine \(audio.engineRunning ? "running" : "stopped"), \(whereAmI())")
        log("screen off: microphone peak \(String(format: "%.3f", peak)), \(blocks) blocks, engine \(audio.engineRunning ? "running" : "stopped")")
        results.set(.mic, round, micOK ? (audio.viaGlasses ? .works : .partly) : .fails)
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
            results.measure(.stt, round, heard.isEmpty ? "nothing heard (stream: \(streamState)\(partial.isEmpty ? "" : ", partial “\(partial)”")), \(whereAmI())" : "heard “\(heard)”, server \(stt.lastLatencyMs ?? -1) ms, \(whereAmI())")
            results.set(.stt, round, heard.isEmpty ? .fails : .works)
            await speak(heard.isEmpty ? "I heard nothing." : "I heard: \(heard)")
        } else {
            results.measure(.stt, round, "skipped: no server address or key")
            await speak("Speech to text skipped, no server set.")
        }
        if Task.isCancelled { return }

        // 3. Display + 4. spoken audio, answered on the lens
        step("display and speech")
        glasses.display.clear()
        glasses.showCard(title: "Screen off test", body: "Did you hear me clearly? Pick Yes or No.")
        await speak("Display test. If you hear this clearly, pick Yes on the display of your glasses. Otherwise pick No.")
        var choice: String?
        for _ in 0..<100 {
            if let last = glasses.display.choices.last { choice = last; break }
            await wait(0.25)
        }
        results.measure(.display, round, "display \(glasses.display.state), sent in \(glasses.display.sendMs ?? -1) ms, answer \(choice ?? "none"), \(whereAmI())")
        if choice == nil { results.measure(.display, round, "why: \(glasses.status)") }
        results.set(.display, round, choice != nil ? .works : .fails)
        if let choice {
            results.measure(.speech, round, "you answered \(choice) on the lens")
            results.set(.speech, round, choice == "Yes" ? .works : .partly)
        } else {
            results.measure(.speech, round, "no answer on the lens; check this test by ear")
        }
        if Task.isCancelled { return }

        // 5. Camera, with the glasses' microphone on the same stream. HEVC:
        // a raw stream pauses as soon as the app is off the screen.
        step("camera")
        await speak("Camera test. Look around, and keep talking, for eight seconds.")
        await glasses.startCameraNow(raw: false, showFrames: false, mic: true, ask: false, resolution: .low)
        for _ in 0..<40 where !glasses.cameraStreaming { await wait(0.25) }
        await wait(8)
        let frames = glasses.frames
        let micBlocks = glasses.micFrames
        let micPeak = glasses.micPeak
        let cameraState = glasses.cameraState
        glasses.stopCamera()
        results.measure(.camera, round, "\(frames) frames in 8 s (hvc1), state \(cameraState), \(whereAmI())")
        results.set(.camera, round, frames > 20 ? .works : (frames > 0 ? .partly : .fails))
        if frames == 0 { results.measure(.camera, round, "why: \(glasses.status)") }
        results.measure(.mic, round, "toolkit route: \(micBlocks) audio blocks, peak \(String(format: "%.3f", micPeak)), \(whereAmI())")
        if micBlocks > 0 && micPeak > 0.01 && !micOK { results.set(.mic, round, .partly) }
        if Task.isCancelled { return }

        // 6. Photo
        step("photo")
        await speak("Photo test. Hold still.")
        let before = glasses.photo
        glasses.takePhoto(raw: false, ask: false)
        var gotPhoto = false
        for _ in 0..<100 {
            if glasses.photo !== before, glasses.photo != nil { gotPhoto = true; break }
            await wait(0.25)
        }
        glasses.stopCamera()
        results.measure(.photo, round, gotPhoto ? "photo after \(glasses.photoMs ?? -1) ms, \(whereAmI())" : "no photo within 25 s (\(glasses.status)), \(whereAmI())")
        results.set(.photo, round, gotPhoto ? .works : .fails)
        if Task.isCancelled { return }

        // 7. Gestures
        step("gestures")
        glasses.startInputs()
        glasses.display.clearInputs()
        audio.clearMediaKeys()
        await speak("Gesture test. For ten seconds: tap, swipe and pinch.")
        audio.beep()
        await wait(10)
        let inputs = glasses.display.inputs
        let keys = audio.mediaKeys
        results.measure(.gestures, round, "glasses inputs: \(inputs.count) (\(Set(inputs.map { $0.components(separatedBy: "(").first ?? $0 }).sorted().joined(separator: ", "))); media buttons: \(keys.joined(separator: ", ").isEmpty ? "none" : keys.joined(separator: ", ")), \(whereAmI())")
        results.set(.gestures, round, inputs.count + keys.count > 0 ? .works : .fails)

        glasses.display.clear()
        step("done")
        await speak("Done. Unlock your phone to see the results.")
        audio.beep(660)
    }
}
