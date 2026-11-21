import Foundation

/// Live speech to text on your own server: 16 kHz PCM over the /v1/stream
/// WebSocket, partial and final text back. The key goes in the Authorization
/// header and never leaves this app otherwise.
final class SttClient: ObservableObject {
    @Published private(set) var state = "off"
    @Published private(set) var partial = ""
    @Published private(set) var finals: [String] = []
    @Published private(set) var lastLatencyMs: Int?

    var onLog: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var buffer = Data()
    private let lock = NSLock()
    private var openedAt = Date()
    private var firstPartialAt: Date?
    private var lastAudioAt = Date()

    var isOn: Bool { task != nil }

    /// GET /health with the key; reports how long it took.
    static func health(base: String, key: String, done: @escaping (String, Bool) -> Void) {
        guard let url = URL(string: base.trimmingCharacters(in: .whitespaces) + "/health") else { done("bad address", false); return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let started = Date()
        URLSession.shared.dataTask(with: request) { data, response, error in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text: String
            if let error { text = "unreachable: \(error.localizedDescription)" }
            else if code == 401 { text = "key refused (401)" }
            else { text = "HTTP \(code) in \(ms) ms: \(String(data: data ?? Data(), encoding: .utf8)?.prefix(40) ?? "")" }
            DispatchQueue.main.async { done(text, code == 200) }
        }.resume()
    }

    func start(base: String, key: String) {
        stop()
        var text = base.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("https://") { text = "wss://" + text.dropFirst(8) }
        else if text.hasPrefix("http://") { text = "ws://" + text.dropFirst(7) }
        guard let url = URL(string: text + "/v1/stream") else { state = "bad address"; return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        openedAt = Date()
        firstPartialAt = nil
        partial = ""
        state = "connecting"
        task.resume()
        receive(task)
        // URLSessionWebSocketTask has no open callback: a ping answers once it is up.
        task.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.task === task else { return }
                if let error {
                    self.state = "failed: \(error.localizedDescription)"
                    self.onLog?("STT stream failed: \(error.localizedDescription)")
                    self.task = nil
                } else {
                    let ms = Int(Date().timeIntervalSince(self.openedAt) * 1000)
                    self.state = "streaming (opened in \(ms) ms)"
                    self.onLog?("STT stream open in \(ms) ms")
                }
            }
        }
    }

    func stop() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        lock.lock(); buffer.removeAll(); lock.unlock()
        if state != "off" { state = "off" }
    }

    func clear() { finals = []; partial = "" }

    /// Audio thread: collects about 100 ms, then sends one binary frame.
    func feed(_ pcm: Data) {
        lock.lock()
        buffer.append(pcm)
        let chunk: Data?
        if buffer.count >= 3200 { chunk = buffer; buffer = Data() } else { chunk = nil }
        lock.unlock()
        guard let chunk, let task else { return }
        lastAudioAt = Date()
        task.send(.data(chunk)) { _ in }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    guard self.task === task else { return }
                    self.state = "closed: \(error.localizedDescription)"
                    self.task = nil
                }
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive(task)
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = json["type"] as? String ?? ""
        let words = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            switch type {
            case "partial":
                if self.firstPartialAt == nil, !words.isEmpty { self.firstPartialAt = Date() }
                self.partial = words
            case "final":
                self.partial = ""
                guard !words.isEmpty else { return }
                self.finals.append(words)
                if self.finals.count > 20 { self.finals.removeFirst() }
                let ms = Int(Date().timeIntervalSince(self.lastAudioAt) * 1000)
                self.lastLatencyMs = json["processing_ms"] as? Int ?? ms
                self.onLog?("STT final: “\(words)” (server \(json["processing_ms"] as? Int ?? -1) ms)")
                self.onFinal?(words)
            case "error":
                self.onLog?("STT error: \(json["error"] ?? json["message"] ?? text)")
            default:
                break
            }
        }
    }
}
