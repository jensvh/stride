import Foundation
import Security

/// The link to the PC: one WebSocket to Azure Web PubSub, speaking the same
/// JSON protocol as the lens (protocol/schema.ts). Everything runs on the main
/// thread. The probe only sends log lines and pings, and voices `speak` events.
final class Relay: NSObject, URLSessionWebSocketDelegate {
    var onStatus: ((String) -> Void)?
    var onNote: ((String) -> Void)?
    var onSpeak: ((String) -> Void)?

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var socket: URLSessionWebSocketTask?
    private var url: URL?
    private var joined = false
    private var outbox: [[String: Any]] = []
    private var attempt = 0
    private var connects = 0
    private var wasConnected = false
    private var awaitingFirstPong = false
    private var pingTimer: Timer?

    // MARK: Pairing

    /// Picks up the relay address saved by an earlier pairing.
    func restore() {
        guard let saved = Keychain.read(), let url = URL(string: saved) else { return }
        self.url = url
        connect()
    }

    /// `stride://pair?r=<base64url of the relay address>`
    func pair(with link: URL) -> Bool {
        guard link.host == "pair",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "r" })?.value,
              let data = Data(base64URL: code),
              let text = String(data: data, encoding: .utf8),
              let url = URL(string: text),
              url.scheme == "wss" || url.scheme == "ws"
        else { return false }
        if !Keychain.save(text) {
            onNote?("relay: could not store the pairing in the keychain, it lasts until the app closes")
        }
        self.url = url
        attempt = 0
        connect()
        return true
    }

    // MARK: Sending

    func log(_ message: String) {
        guard url != nil else { return }
        send(["t": "log", "level": "info", "msg": String(message.prefix(3900))])
    }

    private func send(_ data: [String: Any]) {
        var payload = data
        payload["v"] = 1
        guard joined else {
            outbox.append(payload)
            if outbox.count > 300 { outbox.removeFirst(outbox.count - 300) }
            return
        }
        frame(["type": "sendToGroup", "group": "up", "dataType": "json", "noEcho": true, "data": payload])
    }

    private func frame(_ object: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: Connection

    private func connect() {
        guard let url else { return }
        socket?.cancel(with: .goingAway, reason: nil)
        joined = false
        onStatus?("Connecting")
        let task = session.webSocketTask(with: url, protocols: ["json.webpubsub.azure.v1"])
        socket = task
        task.resume()
        listen(on: task)
        if pingTimer == nil {
            pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.ping() }
        }
    }

    private func listen(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, task === self.socket else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.listen(on: task)
                case .failure(let error):
                    self.lost(error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let frame = object as? [String: Any],
              let type = frame["type"] as? String else { return }

        if type == "ack", !joined {
            guard frame["success"] as? Bool == true else {
                onStatus?("Refused")
                onNote?("relay: the pairing code was refused, run “npm run pair” again")
                return
            }
            joined = true
            attempt = 0
            connects += 1
            wasConnected = true
            awaitingFirstPong = true
            onStatus?("Connected")
            onNote?("relay: connected (#\(connects))")
            send(["t": "hello", "device": "phone", "app": "audio probe"])
            let waiting = outbox
            outbox.removeAll()
            for payload in waiting {
                self.frame(["type": "sendToGroup", "group": "up", "dataType": "json", "noEcho": true, "data": payload])
            }
            ping()
            return
        }

        guard type == "message", let message = frame["data"] as? [String: Any] else { return }
        switch message["t"] as? String {
        case "pong":
            guard awaitingFirstPong, let sentAt = message["n"] as? Double else { return }
            awaitingFirstPong = false
            let took = Int(Date().timeIntervalSince1970 * 1000 - sentAt)
            onNote?("relay: the PC answered in \(took) ms")
        case "speak":
            if message["to"] as? String == "phone", let text = message["text"] as? String {
                onSpeak?(text)
            }
        default:
            break
        }
    }

    private func ping() {
        guard joined else { return }
        send(["t": "ping", "n": (Date().timeIntervalSince1970 * 1000).rounded()])
    }

    private func lost(_ reason: String) {
        guard socket != nil else { return }
        socket = nil
        joined = false
        onStatus?("Offline")
        // One line per outage, not one per retry.
        if wasConnected || attempt == 0 { onNote?("relay: connection lost (\(reason))") }
        wasConnected = false
        attempt += 1
        let delay = min(10.0, 0.5 * pow(2.0, Double(attempt)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.socket == nil else { return }
            self.connect()
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol `protocol`: String?) {
        guard webSocketTask === socket else { return }
        // Joining with an ackId doubles as the check that the link really works.
        frame(["type": "joinGroup", "group": "down", "ackId": 1])
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === socket else { return }
        lost("closed with code \(closeCode.rawValue)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === socket, let error else { return }
        lost(error.localizedDescription)
    }
}

/// The relay address carries a token that lets a device talk to Claude on the
/// PC, so it is kept in the keychain and not in plain preferences.
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "stride.relay",
        kSecAttrAccount as String: "address",
    ]

    static func save(_ value: String) -> Bool {
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        // Readable while the phone is locked, which is when Stride is used.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension Data {
    init?(base64URL text: String) {
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        self.init(base64Encoded: padded)
    }
}
