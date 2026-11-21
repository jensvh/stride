import Foundation

/// The two rounds: every test once with the phone in your hand, then again with
/// the screen off and the phone in your pocket.
enum Round: String, Codable, CaseIterable, Identifiable {
    case screenOn = "Screen on"
    case screenOff = "Screen off"
    var id: String { rawValue }
}

enum TestID: String, Codable, CaseIterable, Identifiable {
    case connect, mic, stt, speech, camera, photo, display, gestures
    var id: String { rawValue }

    var title: String {
        switch self {
        case .connect: return "Connect the glasses"
        case .mic: return "Glasses microphone"
        case .stt: return "Speech to text (your server)"
        case .speech: return "Speech and sound in the glasses"
        case .camera: return "Live camera"
        case .photo: return "Take a photo"
        case .display: return "Custom UI on the display"
        case .gestures: return "Gestures"
        }
    }

    var symbol: String {
        switch self {
        case .connect: return "eyeglasses"
        case .mic: return "mic"
        case .stt: return "text.bubble"
        case .speech: return "speaker.wave.2"
        case .camera: return "video"
        case .photo: return "camera"
        case .display: return "rectangle.on.rectangle"
        case .gestures: return "hand.tap"
        }
    }

    /// Step-by-step instructions shown before the test runs.
    var steps: [String] {
        switch self {
        case .connect:
            return [
                "In the Meta AI app, turn on Developer Mode: Settings → App Info → tap the version number five times.",
                "Put the glasses on and make sure they are connected to the Meta AI app.",
                "Tap Register below. The Meta AI app opens: allow Stride Lab, then come back here.",
                "The status should say registered, with one device.",
            ]
        case .mic:
            return [
                "Tap Start. The phone switches its microphone to the glasses (Bluetooth headset).",
                "Check that “input” names your glasses, not “iPhone Microphone”.",
                "Talk normally: the level bar should move. Stay quiet: it should drop.",
                "Mark whether the glasses' microphone works.",
            ]
        case .stt:
            return [
                "On the PC, run “npm run pair -- --lab” and scan the code with the iPhone camera. That gives this app your server address and key. Or enter them under Settings.",
                "Tap Start and say a sentence in English, then one in Dutch.",
                "Grey text is the server's live guess; white text is final.",
                "Mark whether the text is right and fast enough.",
            ]
        case .speech:
            return [
                "Tap Speak. You should hear a sentence in the glasses, not from the phone.",
                "Tap Beep for a short tone.",
                "Mark whether both came out of the glasses and were easy to understand.",
            ]
        case .camera:
            return [
                "Connect the glasses first (test 1).",
                "Tap Start. The Meta AI app may ask to allow the camera once: allow it and come back.",
                "Look around: the picture below should follow your head.",
                "Note the frame rate, then tap Stop.",
            ]
        case .photo:
            return [
                "Connect the glasses first (test 1).",
                "Tap Take photo. The photo should appear below within a few seconds.",
                "Mark whether it worked and how long it took.",
            ]
        case .display:
            return [
                "Connect the glasses first (test 1).",
                "Tap Show. A Stride Lab card with two buttons appears on the lens.",
                "Use the Neural Band (or the touchpad) to pick “Yes” or “No” on the lens.",
                "The phone counts each choice. Tap Clear when done.",
            ]
        case .gestures:
            return [
                "Tap Start. The app listens for glasses inputs and for media buttons.",
                "Try: tap and double tap on the side of the frame, swipe forward and back.",
                "With the Neural Band: pinch, double pinch, swipe left/right with the thumb, pinch and turn.",
                "Each gesture that reaches the app is listed below. Mark which ones arrived.",
            ]
        }
    }
}

enum Outcome: String, Codable, CaseIterable {
    case works = "Works"
    case partly = "Partly"
    case fails = "Doesn't work"
    case untested = "Not tested"

    var symbol: String {
        switch self {
        case .works: return "checkmark.circle.fill"
        case .partly: return "exclamationmark.circle.fill"
        case .fails: return "xmark.circle.fill"
        case .untested: return "circle"
        }
    }
}

struct TestResult: Codable {
    var outcome: Outcome = .untested
    /// What the app measured itself (latency, sample rate, frames, ...).
    var measured: [String] = []
    var note: String = ""
    var at: Date?
}

/// All results, saved as JSON in the app's Documents folder (visible in Files).
@MainActor
final class ResultStore: ObservableObject {
    @Published private(set) var results: [String: TestResult] = [:]
    private let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("stride-lab-results.json")

    init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: TestResult].self, from: data) {
            results = saved
        }
    }

    private func key(_ test: TestID, _ round: Round) -> String { "\(round.rawValue)/\(test.rawValue)" }

    func result(_ test: TestID, _ round: Round) -> TestResult { results[key(test, round)] ?? TestResult() }

    func set(_ test: TestID, _ round: Round, _ outcome: Outcome) {
        var r = result(test, round)
        r.outcome = outcome
        r.at = Date()
        results[key(test, round)] = r
        save()
    }

    func measure(_ test: TestID, _ round: Round, _ line: String) {
        var r = result(test, round)
        r.measured.append(line)
        if r.measured.count > 12 { r.measured.removeFirst(r.measured.count - 12) }
        r.at = Date()
        results[key(test, round)] = r
        save()
    }

    func note(_ test: TestID, _ round: Round, _ text: String) {
        var r = result(test, round)
        r.note = text
        results[key(test, round)] = r
        save()
    }

    func reset() {
        results = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(results) { try? data.write(to: file, options: .atomic) }
    }

    /// Plain-text report to share with the PC or paste into a chat.
    func report() -> String {
        var lines = ["Stride Lab results, \(Date().formatted(date: .abbreviated, time: .shortened))", ""]
        for round in Round.allCases {
            lines.append("== \(round.rawValue) ==")
            for test in TestID.allCases {
                let r = result(test, round)
                lines.append("\(test.title): \(r.outcome.rawValue)")
                for m in r.measured { lines.append("   · \(m)") }
                if !r.note.isEmpty { lines.append("   note: \(r.note)") }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
