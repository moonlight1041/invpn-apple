import Foundation

/// Persisted credentials — mirrors Android `invpn/SecureStore.Credentials`. The password is
/// NEVER stored; only the device token + derived body key (+ salt for login accounts) are kept.
struct Credentials: Codable {
    let username: String
    let deviceToken: String
    let saltBodyB64: String
    let bodyKeyB64: String
    var level: String
    var displayName: String?

    init(username: String, deviceToken: String, saltBodyB64: String, bodyKeyB64: String,
         level: String = "GOLDEN", displayName: String? = nil) {
        self.username = username
        self.deviceToken = deviceToken
        self.saltBodyB64 = saltBodyB64
        self.bodyKeyB64 = bodyKeyB64
        self.level = level
        self.displayName = displayName
    }
}

/// Keychain-backed credential store. The iOS Keychain provides the at-rest protection that the
/// AndroidKeystore-wrapped blob did on Android. Mirrors `invpn/SecureStore.kt`.
enum SecureStore {
    private static let service = "com.invpn.app.creds"
    private static let account = "default"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ c: Credentials) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        SecItemDelete(baseQuery() as CFDictionary)
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> Credentials? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    static var isLoggedIn: Bool { load() != nil }
}
