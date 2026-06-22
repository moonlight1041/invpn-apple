import Foundation

/// Register/login/redeem against the config API and persist credentials; the body_key is derived
/// locally from the password (never stored) or returned over TLS for passwordless invites.
/// Mirrors Android `invpn/AuthRepository.kt`; ObservableObject so SwiftUI reacts to login/logout.
@MainActor
final class AuthRepository: ObservableObject {
    static let shared = AuthRepository()

    /// Drives the auth gate: true → app, false → login screen.
    @Published private(set) var isAuthenticated: Bool = SecureStore.isLoggedIn

    var username: String? { SecureStore.load()?.username }
    var displayName: String? { SecureStore.load()?.displayName }
    var level: String { SecureStore.load()?.level ?? "GOLDEN" }
    var isBrilliant: Bool { level == "BRILLIANT" }

    /// login+password: body_key derived from the password (never stored).
    func login(username: String, password: String) async throws {
        let r = try await ApiClient.shared.login(username: username, password: password)
        let bodyKey = Crypto.deriveBodyKey(password: password, salt: try Crypto.b64UrlDecode(r.salt_body))
        SecureStore.save(Credentials(
            username: username, deviceToken: r.device_token,
            saltBodyB64: r.salt_body, bodyKeyB64: Crypto.b64UrlEncode(bodyKey),
            level: r.level ?? "GOLDEN", displayName: r.name))
        isAuthenticated = true
    }

    /// passwordless invite-link redemption: body_key arrives from the server over TLS.
    func redeemInvite(code: String) async throws {
        let r = try await ApiClient.shared.redeem(code: code)
        SecureStore.save(Credentials(
            username: r.name ?? "(invite)", deviceToken: r.device_token,
            saltBodyB64: "", bodyKeyB64: r.body_key,
            level: r.level ?? "GOLDEN", displayName: r.name))
        isAuthenticated = true
    }

    /// BRILLIANT only — mint an invite link and return it.
    func createInvite(name: String?, level: String) async throws -> String {
        guard let token = SecureStore.load()?.deviceToken else {
            throw ApiException(code: -1, message: "not authenticated")
        }
        return try await ApiClient.shared.createInvite(deviceToken: token, name: name, level: level).link
    }

    func logout() {
        SecureStore.clear()
        isAuthenticated = false
    }
}
