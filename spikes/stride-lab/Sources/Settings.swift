import Foundation
import Security

/// STT server address (UserDefaults) and key (Keychain, this device only).
@MainActor
final class LabSettings: ObservableObject {
    @Published var sttURL: String {
        didSet { UserDefaults.standard.set(sttURL, forKey: "sttURL") }
    }
    @Published private(set) var hasKey: Bool

    init() {
        sttURL = UserDefaults.standard.string(forKey: "sttURL") ?? ""
        hasKey = Keychain.read("sttKey") != nil
    }

    var sttKey: String? { Keychain.read("sttKey") }

    func setKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete("sttKey") } else { Keychain.write("sttKey", trimmed) }
        hasKey = Keychain.read("sttKey") != nil
    }

    /// stridelab://config?stt=<url>&key=<key>, from the PC's `npm run pair -- --lab` page.
    func apply(configURL url: URL) -> Bool {
        guard url.scheme == "stridelab", url.host == "config",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        if let stt = items.first(where: { $0.name == "stt" })?.value, !stt.isEmpty { sttURL = stt }
        if let key = items.first(where: { $0.name == "key" })?.value, !key.isEmpty { setKey(key) }
        return true
    }
}

enum Keychain {
    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.jensvh.stride.lab",
         kSecAttrAccount as String: name]
    }

    static func read(_ name: String) -> String? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ name: String, _ value: String) {
        delete(name)
        var q = query(name)
        q[kSecValueData as String] = Data(value.utf8)
        // Available while the phone is locked after the first unlock: the
        // screen-off round needs the key in your pocket.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ name: String) {
        SecItemDelete(query(name) as CFDictionary)
    }
}
