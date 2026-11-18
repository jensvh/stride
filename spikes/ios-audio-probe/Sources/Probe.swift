import AVFoundation
import MediaPlayer
import Speech
import SwiftUI
import UIKit

struct LogLine: Identifiable {
    let id: Int
    let time: String
    let text: String
}

struct MicInput: Identifiable, Hashable {
    let id: String
    let label: String
}

struct Finding: Identifiable {
    enum Verdict { case unknown, good, bad }
    /// The question, which doubles as the row title.
    let id: String
    var answer: String
    var verdict: Verdict
}

/// Throwaway spike. It answers four questions on a real iPhone with the glasses
/// connected, because none of them can be tested on a build machine:
///   1. Does the glasses' microphone reach the app over Bluetooth?
///   2. Does on-device speech recognition work on that audio?
///   3. Does a tap on the glasses' temple reach the app?
///   4. Does all of it keep running while the phone is locked in a pocket?
final class Probe: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    // MARK: Shown on screen. Changed on the main thread only.

    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var findings: [Finding] = []
    @Published private(set) var running = false
    @Published private(set) var level: Double = 0
    @Published private(set) var heard = ""
    @Published private(set) var inputs: [MicInput] = []
    @Published private(set) var selectedInput = ""
    @Published private(set) var relayStatus = "Not paired"
    @Published var echo = true

    // MARK: Audio

    private let session = AVAudioSession.sharedInstance()
    private var engine = AVAudioEngine()
    private var beeper = AVAudioPlayerNode()
    private let toneFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
    private let synth = AVSpeechSynthesizer()

    /// Guards everything the audio thread shares with the main thread.
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var feeding = false
    private var bufferCount = 0
    private var lastBufferAt = Date.distantPast
    private var peak: Float = 0
    private var voiceStartedAt: Date?
    private var lastLevelAt = Date.distantPast

    // MARK: Speech

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var task: SFSpeechRecognitionTask?
    private var speechAllowed = false
    private var generation = 0
    private var listening = false
    private var awaitingFinalSince: Date?
    private var phraseStartedAt = Date()
    private var lastWordsAt = Date()
    private var firstWordsPending = false
    private var speechErrors = 0
    private var phrases = 0
    private var firstWordDelays: [Int] = []
    private var finishDelays: [Int] = []
    private var endedAudioAt: Date?

    // MARK: Glasses buttons, background, bookkeeping

    private var remoteReady = false
    private var taps: [String: Int] = [:]
    private var inBackground = false
    private var awaySeconds = 0
    private var awayAudioSeconds = 0
    private var awayPhrases = 0
    private var longestPause: TimeInterval = 0
    private var timer: Timer?
    private var ticks = 0
    private var lastTickAt = Date()
    private var audioWasFlowing = false
    private var sampleRate: Double = 0

    private let relay = Relay()
    private var counter = 0
    private var file: FileHandle?
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    override init() {
        super.init()
        synth.delegate = self
        let previous = openLogFile()
        refreshFindings()

        let device = UIDevice.current
        log("probe \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") on \(device.model), iOS \(device.systemVersion)")
        if let previous { log("previous run ended with: \(previous)") }

        relay.onStatus = { [weak self] status in self?.relayStatus = status }
        relay.onNote = { [weak self] note in self?.log(note) }
        relay.onSpeak = { [weak self] text in self?.say(text) }
        relay.restore()

        observe()
    }

    // MARK: - Start and stop

    func start() {
        guard !running else { return }
        AVAudioApplication.requestRecordPermission { [weak self] micAllowed in
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    self?.begin(micAllowed: micAllowed, speechAllowed: status == .authorized)
                }
            }
        }
    }

    private func begin(micAllowed: Bool, speechAllowed: Bool) {
        guard !running else { return }
        guard micAllowed else {
            log("microphone: permission denied. Allow it in Settings → Stride Probe.")
            return
        }
        self.speechAllowed = speechAllowed
        if !speechAllowed { log("speech: permission denied. Allow it in Settings → Stride Probe.") }

        do {
            // playAndRecord + the hands-free profile is what makes iOS offer the glasses' microphone.
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            log("audio session: could not start (\(describe(error)))")
            return
        }
        log("audio session: active")
        refreshRoute(note: "route")

        guard startEngine() else { return }
        setUpGlassesButtons()
        running = true
        startTimer()
        startListening(announce: true)
    }

    func stop() {
        guard running else { return }
        running = false
        cancelRecognition()
        synth.stopSpeaking(at: .immediate)
        timer?.invalidate()
        timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        level = 0
        heard = ""
        log("stopped")
        refreshFindings()
    }

    // MARK: - Engine

    /// A fresh engine on every start: after a route change an old engine can
    /// keep reporting the previous microphone's format.
    private func startEngine() -> Bool {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        beeper = AVAudioPlayerNode()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log("microphone: no usable input (\(format.sampleRate) Hz, \(format.channelCount) channels)")
            return false
        }
        sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.received(buffer)
        }
        engine.attach(beeper)
        engine.connect(beeper, to: engine.mainMixerNode, format: toneFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            log("audio engine: could not start (\(describe(error)))")
            return false
        }
        log("audio engine: running, microphone at \(Int(format.sampleRate)) Hz, \(format.channelCount) channel(s)")
        return true
    }

    private func restartEngine(reason: String) {
        guard running else { return }
        log("audio engine: restarting (\(reason))")
        cancelRecognition()
        try? session.setActive(true)
        refreshRoute(note: "route")
        if startEngine() {
            startListening(announce: false)
        } else {
            log("audio engine: restart failed, press Stop and Start")
        }
    }

    /// Called on the audio thread for every chunk of microphone audio.
    private func received(_ buffer: AVAudioPCMBuffer) {
        var rms: Float = 0
        if let samples = buffer.floatChannelData?[0] {
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for index in 0..<count { sum += samples[index] * samples[index] }
            if count > 0 { rms = (sum / Float(count)).squareRoot() }
        }
        let now = Date()

        lock.lock()
        bufferCount += 1
        lastBufferAt = now
        peak = max(peak, rms)
        if feeding, voiceStartedAt == nil, rms > 0.02 { voiceStartedAt = now }
        let target = feeding ? request : nil
        let showLevel = now.timeIntervalSince(lastLevelAt) > 0.1
        if showLevel { lastLevelAt = now }
        lock.unlock()

        target?.append(buffer)
        if showLevel {
            DispatchQueue.main.async { self.level = Double(min(1, rms * 6)) }
        }
    }

    // MARK: - Speech recognition

    private func startListening(announce: Bool) {
        guard running, speechAllowed else { return }
        guard let recognizer, recognizer.isAvailable else {
            log("speech: recognizer not available right now")
            later(3) { [weak self] in self?.startListening(announce: announce) }
            return
        }
        cancelRecognition()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // Never fall back to Apple's servers without saying so: the point is to learn whether the phone can do it alone.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        generation += 1
        let mine = generation
        heard = ""
        firstWordsPending = true
        phraseStartedAt = Date()
        lastWordsAt = Date()
        awaitingFinalSince = nil
        endedAudioAt = nil
        lock.lock()
        self.request = request
        feeding = true
        voiceStartedAt = nil
        lock.unlock()
        listening = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            DispatchQueue.main.async {
                self?.recognized(generation: mine, text: text, isFinal: isFinal, error: error)
            }
        }
        if announce { beep(880) }
    }

    private func recognized(generation: Int, text: String?, isFinal: Bool, error: Error?) {
        guard generation == self.generation else { return }

        if let text {
            if text != heard {
                heard = text
                lastWordsAt = Date()
            }
            if firstWordsPending, !text.isEmpty {
                firstWordsPending = false
                lock.lock()
                let voice = voiceStartedAt
                lock.unlock()
                if let voice {
                    let delay = Int(Date().timeIntervalSince(voice) * 1000)
                    firstWordDelays.append(delay)
                    log("speech: first words \(delay) ms after you started talking")
                }
            }
            if isFinal {
                phraseDone(text)
                return
            }
        }

        guard let error else { return }
        if !heard.isEmpty {
            // The recognizer gave up after it had words: keep them.
            phraseDone(heard)
            return
        }
        let code = (error as NSError).code
        let quiet = code == 1110 || code == 203 || code == 216 || code == 301
        if quiet {
            // "No speech detected" and friends: normal while nobody talks.
            self.generation += 1
            listening = false
            later(0.3) { [weak self] in self?.startListening(announce: false) }
            return
        }
        speechErrors += 1
        log("speech: error \(describe(error))")
        self.generation += 1
        listening = false
        if speechErrors >= 5 {
            log("speech: stopped trying after 5 errors in a row")
            return
        }
        later(1.5) { [weak self] in self?.startListening(announce: false) }
    }

    /// You stopped talking (or the phrase got too long): ask for the final text.
    private func endPhrase() {
        guard listening, awaitingFinalSince == nil else { return }
        lock.lock()
        feeding = false
        let request = self.request
        lock.unlock()
        awaitingFinalSince = Date()
        endedAudioAt = Date()
        request?.endAudio()
    }

    private func phraseDone(_ text: String) {
        if let endedAudioAt {
            finishDelays.append(Int(Date().timeIntervalSince(endedAudioAt) * 1000))
        }
        cancelRecognition()
        speechErrors = 0
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            startListening(announce: false)
            return
        }
        phrases += 1
        if inBackground { awayPhrases += 1 }
        log("speech: heard “\(trimmed)”\(inBackground ? " (phone locked or app in background)" : "")")
        if echo {
            say("I heard: \(trimmed)")
        } else {
            beep(660)
            startListening(announce: false)
        }
    }

    private func cancelRecognition() {
        generation += 1
        listening = false
        awaitingFinalSince = nil
        lock.lock()
        request = nil
        feeding = false
        lock.unlock()
        task?.cancel()
        task = nil
    }

    // MARK: - Speaking and tones

    func speakTest() {
        say("Stride probe speaking through your glasses. One, two, three.")
    }

    /// Speaks through the current route. Recognition pauses meanwhile, or the
    /// open-ear speakers of the glasses would be transcribed as your own words.
    private func say(_ text: String) {
        guard running else { return }
        cancelRecognition()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.startListening(announce: true) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.startListening(announce: false) }
    }

    private func beep(_ frequency: Double) {
        guard running, engine.isRunning, let toneFormat else { return }
        let seconds = 0.12
        let frames = AVAudioFrameCount(toneFormat.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: toneFormat, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            let t = Double(index) / toneFormat.sampleRate
            let fade = min(1.0, min(t, seconds - t) / 0.01)
            samples[index] = Float(sin(2.0 * Double.pi * frequency * t) * 0.25 * fade)
        }
        beeper.scheduleBuffer(buffer, completionHandler: nil)
        if !beeper.isPlaying { beeper.play() }
    }

    // MARK: - Microphone choice and route

    func choose(input id: String) {
        guard let port = session.availableInputs?.first(where: { $0.uid == id }) else { return }
        do {
            try session.setPreferredInput(port)
            log("microphone: you chose \(port.portName)")
        } catch {
            log("microphone: could not switch to \(port.portName) (\(describe(error)))")
        }
        selectedInput = id
    }

    private func refreshRoute(note: String) {
        let available = session.availableInputs ?? []
        inputs = available.map { MicInput(id: $0.uid, label: "\($0.portName) · \(kind($0.portType))") }
        let route = session.currentRoute
        selectedInput = route.inputs.first?.uid ?? ""
        let ins = route.inputs.map { "\($0.portName) [\(kind($0.portType))]" }.joined(separator: ", ")
        let outs = route.outputs.map { "\($0.portName) [\(kind($0.portType))]" }.joined(separator: ", ")
        log("\(note): microphone = \(ins.isEmpty ? "none" : ins); sound = \(outs.isEmpty ? "none" : outs)")
    }

    private func kind(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .bluetoothHFP: return "Bluetooth hands-free"
        case .bluetoothA2DP: return "Bluetooth music"
        case .bluetoothLE: return "Bluetooth LE"
        case .builtInMic: return "iPhone microphone"
        case .builtInSpeaker: return "iPhone speaker"
        case .builtInReceiver: return "iPhone earpiece"
        case .headsetMic: return "wired headset"
        case .headphones: return "wired headphones"
        default: return type.rawValue
        }
    }

    // MARK: - Glasses buttons

    /// A tap on the temple normally means play/pause. Whether it reaches an app
    /// that holds the microphone is what we want to find out.
    private func setUpGlassesButtons() {
        guard !remoteReady else { return }
        remoteReady = true
        let center = MPRemoteCommandCenter.shared()
        let commands: [(String, MPRemoteCommand)] = [
            ("play", center.playCommand),
            ("pause", center.pauseCommand),
            ("play/pause", center.togglePlayPauseCommand),
            ("next", center.nextTrackCommand),
            ("previous", center.previousTrackCommand),
            ("stop", center.stopCommand),
        ]
        for (name, command) in commands {
            command.isEnabled = true
            _ = command.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.buttonPressed(name) }
                return .success
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Stride probe",
            MPMediaItemPropertyArtist: "Listening",
        ]
    }

    private func buttonPressed(_ name: String) {
        taps[name, default: 0] += 1
        log("glasses button: \(name)\(inBackground ? " (phone locked or app in background)" : "")")
        beep(520)
        refreshFindings()
    }

    // MARK: - Pairing with the PC

    func pair(_ link: URL) {
        if relay.pair(with: link) {
            log("relay: paired, connecting")
        } else {
            log("relay: that code is not a Stride pairing code")
        }
    }

    // MARK: - Notifications from iOS

    private func observe() {
        let center = NotificationCenter.default

        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            self.refreshRoute(note: "route changed (\(self.reason(raw)))")
            // The engine usually reports the change itself. If it stays silent, restart it here.
            self.later(0.6) { [weak self] in
                guard let self, self.running, !self.engine.isRunning else { return }
                self.restartEngine(reason: "route change")
            }
        }

        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine else { return }
            self.later(0.3) { [weak self] in self?.restartEngine(reason: "audio hardware changed") }
        }

        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            if AVAudioSession.InterruptionType(rawValue: raw) == .began {
                self.log("interrupted by another app or a call")
                self.cancelRecognition()
            } else {
                let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                self.log("interruption ended\(options.contains(.shouldResume) ? ", iOS says resume" : "")")
                self.later(0.3) { [weak self] in self?.restartEngine(reason: "after interruption") }
            }
        }

        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log("iOS restarted its audio system")
            self?.later(0.5) { [weak self] in self?.restartEngine(reason: "audio system restart") }
        }

        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.inBackground = true
            self?.log("app went to the background")
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.inBackground = false
            self?.log("app is back in front")
            self?.refreshFindings()
        }
        center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log("phone locked")
        }
        center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log("phone unlocked")
        }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log("app is being closed")
        }
    }

    private func reason(_ raw: UInt) -> String {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return "reason \(raw)" }
        switch reason {
        case .newDeviceAvailable: return "device connected"
        case .oldDeviceUnavailable: return "device disconnected"
        case .categoryChange: return "category change"
        case .override: return "override"
        case .wakeFromSleep: return "wake from sleep"
        case .noSuitableRouteForCategory: return "no suitable route"
        case .routeConfigurationChange: return "configuration change"
        default: return "reason \(raw)"
        }
    }

    // MARK: - Heartbeat

    private func startTimer() {
        timer?.invalidate()
        ticks = 0
        lastTickAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let now = Date()
        let gap = now.timeIntervalSince(lastTickAt)
        lastTickAt = now
        if gap > 3 {
            // Timers only stop when iOS suspends the app: exactly what must not happen on a walk.
            longestPause = max(longestPause, gap)
            log("the app was paused by iOS for \(Int(gap)) s")
        }

        // End of phrase: words were heard and then nothing new for a moment.
        if listening, awaitingFinalSince == nil {
            if !heard.isEmpty, now.timeIntervalSince(lastWordsAt) > 1.6 {
                endPhrase()
            } else if now.timeIntervalSince(phraseStartedAt) > 40 {
                endPhrase()
            }
        } else if let since = awaitingFinalSince, now.timeIntervalSince(since) > 4 {
            log("speech: no final text within 4 s, keeping what was heard so far")
            phraseDone(heard)
        }

        ticks += 1
        guard ticks % 4 == 0 else { return }

        lock.lock()
        let last = lastBufferAt
        let count = bufferCount
        lock.unlock()
        let flowing = now.timeIntervalSince(last) < 2
        if flowing != audioWasFlowing {
            audioWasFlowing = flowing
            log(flowing ? "microphone: audio is arriving" : "microphone: no audio for 2 s")
        }
        if inBackground {
            awaySeconds += 1
            if flowing { awayAudioSeconds += 1 }
        }
        if ticks % 240 == 0 {
            log("still running: \(count) audio chunks, \(phrases) phrases, \(inBackground ? "in background" : "in front"), PC link \(relayStatus.lowercased())")
        }
        refreshFindings()
    }

    // MARK: - The four answers

    private func refreshFindings() {
        lock.lock()
        let peak = self.peak
        lock.unlock()

        var list: [Finding] = []

        // 1. Glasses microphone
        let input = session.currentRoute.inputs.first
        if !running {
            list.append(Finding(id: "Glasses microphone", answer: "Connect the glasses, then press Start.", verdict: .unknown))
        } else if let input, input.portType == .bluetoothHFP || input.portType == .bluetoothLE {
            let hears = peak > 0.01
            list.append(Finding(
                id: "Glasses microphone",
                answer: "\(input.portName) at \(Int(sampleRate)) Hz. \(hears ? "Sound is coming in." : "No sound yet, say something.")",
                verdict: hears && audioWasFlowing ? .good : .unknown))
        } else {
            list.append(Finding(
                id: "Glasses microphone",
                answer: "Listening through \(input?.portName ?? "nothing"), not the glasses. Pick them under Microphone.",
                verdict: .bad))
        }

        // 2. Speech recognition on the phone
        let onDevice = recognizer?.supportsOnDeviceRecognition ?? false
        if recognizer == nil {
            list.append(Finding(id: "Speech to text on the iPhone", answer: "English recognition is not available on this iPhone.", verdict: .bad))
        } else if phrases == 0 {
            list.append(Finding(
                id: "Speech to text on the iPhone",
                answer: onDevice ? "Supported. Say a sentence to try it." : "Only through Apple's servers on this iPhone. Say a sentence to try it.",
                verdict: .unknown))
        } else {
            var parts = ["\(phrases) phrase\(phrases == 1 ? "" : "s") understood"]
            parts.append(onDevice ? "on the phone itself" : "through Apple's servers")
            if let first = median(firstWordDelays) { parts.append("first words after about \(first) ms") }
            if let finish = median(finishDelays) { parts.append("final text \(finish) ms after you stop") }
            list.append(Finding(id: "Speech to text on the iPhone", answer: parts.joined(separator: ", ") + ".", verdict: onDevice ? .good : .unknown))
        }

        // 3. Temple tap
        if taps.isEmpty {
            list.append(Finding(id: "Tap on the glasses", answer: "Nothing received yet. Tap the temple once, then twice.", verdict: .unknown))
        } else {
            let seen = taps.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            list.append(Finding(id: "Tap on the glasses", answer: "Received: \(seen).", verdict: .good))
        }

        // 4. Locked in a pocket
        if awaySeconds < 20 {
            list.append(Finding(id: "Phone locked", answer: "Not tested yet. Lock the phone for a minute and keep talking.", verdict: .unknown))
        } else {
            let share = Int((Double(awayAudioSeconds) / Double(awaySeconds) * 100).rounded())
            let good = share >= 95 && longestPause < 5
            list.append(Finding(
                id: "Phone locked",
                answer: "Away for \(duration(awaySeconds)): microphone kept running \(share)% of the time, \(awayPhrases) phrase\(awayPhrases == 1 ? "" : "s") understood, longest pause \(Int(longestPause)) s.",
                verdict: good ? .good : .bad))
        }

        findings = list
    }

    private func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    private func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }

    // MARK: - Log

    /// Everything worth knowing, in the order it happened. Also written to a
    /// file and, when paired, sent to the PC (bridge/logs/phone.log).
    func log(_ text: String) {
        let now = Date()
        let work = { [self] in
            counter += 1
            let line = LogLine(id: counter, time: clock.string(from: now), text: text)
            lines.append(line)
            if lines.count > 800 { lines.removeFirst(lines.count - 800) }
            try? file?.write(contentsOf: Data("\(line.time) \(text)\n".utf8))
            relay.log("probe: \(text)")
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// The text behind the share button.
    func report() -> String {
        let answers = findings.map { "\($0.id): \($0.answer)" }.joined(separator: "\n")
        let all = lines.map { "\($0.time) \($0.text)" }.joined(separator: "\n")
        return "Stride probe\n\n\(answers)\n\n\(all)\n"
    }

    /// Returns the last line of the previous run, which tells how that run ended.
    private func openLogFile() -> String? {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = folder.appendingPathComponent("probe.log")
        var previous: String?
        if let old = try? String(contentsOf: url, encoding: .utf8) {
            previous = old.split(separator: "\n").last.map(String.init)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
        return previous
    }

    private func describe(_ error: Error) -> String {
        let detail = error as NSError
        return "\(detail.localizedDescription) [\(detail.domain) \(detail.code)]"
    }

    private func later(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
