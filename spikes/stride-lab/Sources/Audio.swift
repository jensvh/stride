import AVFoundation
import MediaPlayer
import UIKit

/// Microphone, speech and sound through the glasses' Bluetooth headset link.
/// One engine serves every test: the level meter, 16 kHz PCM for the STT
/// server, spoken text, beeps, and media buttons (taps on the glasses).
final class Audio: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var running = false
    @Published private(set) var level: Double = 0
    @Published private(set) var input = "—"
    @Published private(set) var output = "—"
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var viaGlasses = false
    @Published private(set) var speaking = false
    @Published private(set) var mediaKeys: [String] = []

    /// Called on the audio thread with 16 kHz, 16-bit mono PCM.
    var onPCM: ((Data) -> Void)?
    var onLog: ((String) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let toneFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let synth = AVSpeechSynthesizer()
    private var lastLevelAt = Date.distantPast
    private var remoteReady = false
    private(set) var peak: Float = 0
    private let lock = NSLock()

    override init() {
        super.init()
        synth.delegate = self
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRoute()
            self?.onLog?("audio route changed: in \(self?.input ?? "?"), out \(self?.output ?? "?")")
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine, self.running else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in _ = self?.startEngine() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let began = AVAudioSession.InterruptionType(rawValue: raw) == .began
            self?.onLog?(began ? "audio interrupted (call or other app)" : "audio interruption ended")
            if !began, self?.running == true {
                try? self?.session.setActive(true)
                _ = self?.startEngine()
            }
        }
    }

    // MARK: Start and stop

    func start(completion: @escaping (Bool) -> Void = { _ in }) {
        if running { completion(true); return }
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else {
                    self.onLog?("microphone permission denied: allow it in Settings → Stride Lab")
                    completion(false)
                    return
                }
                completion(self.begin())
            }
        }
    }

    private func begin() -> Bool {
        do {
            // playAndRecord + hands-free profile = iOS offers the glasses' microphone.
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            onLog?("audio session failed: \(error.localizedDescription)")
            return false
        }
        if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? session.setPreferredInput(glasses)
        }
        refreshRoute()
        guard startEngine() else { return false }
        setUpMediaKeys()
        running = true
        onLog?("audio on: in \(input), out \(output), \(Int(sampleRate)) Hz")
        return true
    }

    func stop() {
        guard running else { return }
        running = false
        synth.stopSpeaking(at: .immediate)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        level = 0
        onLog?("audio off")
    }

    /// A fresh engine each time: after a route change an old one can keep the
    /// previous microphone's format.
    private func startEngine() -> Bool {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        let mic = engine.inputNode
        let format = mic.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onLog?("no usable microphone (\(format.sampleRate) Hz)")
            return false
        }
        sampleRate = format.sampleRate
        converter = AVAudioConverter(from: format, to: pcmFormat)
        mic.installTap(onBus: 0, bufferSize: 1600, format: format) { [weak self] buffer, _ in
            self?.received(buffer)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: toneFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            onLog?("audio engine failed: \(error.localizedDescription)")
            return false
        }
        return true
    }

    /// Audio thread.
    private func received(_ buffer: AVAudioPCMBuffer) {
        var rms: Float = 0
        if let samples = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += samples[i] * samples[i] }
            if n > 0 { rms = (sum / Float(n)).squareRoot() }
        }
        lock.lock()
        peak = max(peak, rms)
        lock.unlock()

        if let onPCM, let converter {
            let ratio = pcmFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            if let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) {
                var fed = false
                var error: NSError?
                converter.convert(to: out, error: &error) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                if error == nil, out.frameLength > 0, let data = out.int16ChannelData?[0] {
                    onPCM(Data(bytes: data, count: Int(out.frameLength) * 2))
                }
            }
        }

        let now = Date()
        if now.timeIntervalSince(lastLevelAt) > 0.1 {
            lastLevelAt = now
            let value = Double(min(1, rms * 6))
            DispatchQueue.main.async { self.level = value }
        }
    }

    func resetPeak() {
        lock.lock(); peak = 0; lock.unlock()
    }

    var currentPeak: Float {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    // MARK: Speech and tones

    func say(_ text: String) {
        if !running { start { [weak self] ok in if ok { self?.say(text) } }; return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        speaking = true
        synth.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = false }
    }

    func beep(_ frequency: Double = 880, seconds: Double = 0.15) {
        if !running { start { [weak self] ok in if ok { self?.beep(frequency, seconds: seconds) } }; return }
        guard engine.isRunning else { return }
        let frames = AVAudioFrameCount(toneFormat.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: toneFormat, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / toneFormat.sampleRate
            let fade = min(1.0, min(t, seconds - t) / 0.01)
            samples[i] = Float(sin(2.0 * Double.pi * frequency * t) * 0.3 * fade)
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    // MARK: Route

    private func refreshRoute() {
        let route = session.currentRoute
        let mic = route.inputs.first
        input = mic.map { "\($0.portName) (\(kind($0.portType)))" } ?? "none"
        output = route.outputs.map { "\($0.portName) (\(kind($0.portType)))" }.joined(separator: ", ")
        if output.isEmpty { output = "none" }
        viaGlasses = mic?.portType == .bluetoothHFP || mic?.portType == .bluetoothLE
    }

    private func kind(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .bluetoothHFP: return "Bluetooth headset"
        case .bluetoothA2DP: return "Bluetooth audio"
        case .bluetoothLE: return "Bluetooth LE"
        case .builtInMic: return "iPhone mic"
        case .builtInSpeaker: return "iPhone speaker"
        case .builtInReceiver: return "iPhone earpiece"
        default: return type.rawValue
        }
    }

    // MARK: Media buttons (taps on the glasses)

    private func setUpMediaKeys() {
        guard !remoteReady else { return }
        remoteReady = true
        let center = MPRemoteCommandCenter.shared()
        let commands: [(String, MPRemoteCommand)] = [
            ("play", center.playCommand), ("pause", center.pauseCommand),
            ("play/pause", center.togglePlayPauseCommand), ("next", center.nextTrackCommand),
            ("previous", center.previousTrackCommand), ("stop", center.stopCommand),
        ]
        for (name, command) in commands {
            command.isEnabled = true
            _ = command.addTarget { [weak self] _ in
                DispatchQueue.main.async {
                    self?.mediaKeys.append(name)
                    self?.onLog?("media button: \(name)")
                }
                return .success
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Stride Lab", MPMediaItemPropertyArtist: "Testing"]
    }

    func clearMediaKeys() { mediaKeys = [] }
}
