import Foundation

// Wire models — property names match the backend JSON (snake_case) so Codable maps directly.
struct AuthResult: Codable { let device_token: String; let salt_body: String; let level: String?; let name: String? }
struct ConfigBlob: Codable { let v: Int?; let alg: String?; let nonce: String; let ct: String }
struct RedeemResult: Codable { let device_token: String; let body_key: String; let name: String?; let level: String? }
struct InviteResult: Codable { let code: String; let link: String; let level: String?; let invitee_name: String? }

struct ApiException: Error, LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
}

/// Authenticated config-delivery client — mirrors Android `invpn/ApiClient.kt`, same ofjnb.net
/// contract. Async URLSession. (SPKI pinning prepared in PinningDelegate but disabled until the
/// pins are verified on-device — see InVpnConfig.pins.)
final class ApiClient {
    static let shared = ApiClient()
    private let session: URLSession
    private let decoder = JSONDecoder()

    init() {
        session = URLSession(configuration: .ephemeral, delegate: PinningDelegate(), delegateQueue: nil)
    }

    func login(username: String, password: String) async throws -> AuthResult {
        try await post("/api/v1/login", body: ["username": username, "password": password])
    }

    /// Passwordless invite redemption — server returns device_token + body_key + name + level.
    func redeem(code: String) async throws -> RedeemResult {
        try await post("/api/v1/redeem", body: ["code": code])
    }

    /// BRILLIANT only — mint an invite; returns the shareable link.
    func createInvite(deviceToken: String, name: String?, level: String) async throws -> InviteResult {
        var body: [String: Any] = ["level": level]
        body["invitee_name"] = name ?? NSNull()       // explicit JSON null, not a Swift Optional
        return try await post("/api/v1/invites", body: body, bearer: deviceToken)
    }

    func fetchConfig(deviceToken: String) async throws -> ConfigBlob {
        try await post("/api/v1/config", body: [:], bearer: deviceToken)
    }

    /// POST a pre-serialised telemetry envelope to /t/v1/events.
    ///
    /// - Parameters:
    ///   - token:    Device token — sent as `Authorization: Bearer <token>`.
    ///   - envelope: AES-256-GCM envelope JSON produced by `TelemetryCrypto.sealBatch`.
    /// - Returns: HTTP status code (200 / 400 / 401 / …), or 0 on transport error.
    ///
    /// Never throws — returns 0 on any URLError so the caller can handle it as a
    /// retriable failure without crashing the telemetry flush.
    func postTelemetry(token: String, envelope: Data) async -> Int {
        guard let url = URL(string: InVpnConfig.apiBase + "/t/v1/events") else { return 0 }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = envelope
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return 0
        }
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], bearer: String? = nil) async throws -> T {
        guard let url = URL(string: InVpnConfig.apiBase + path) else {
            throw ApiException(code: -1, message: "bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if !(200...299).contains(code) {
            let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw ApiException(code: code, message: (msg?["error"] as? String) ?? "HTTP \(code)")
        }
        return try decoder.decode(T.self, from: data)
    }
}

/// System CA validation first, then (when InVpnConfig.pins is non-empty) an SPKI any-match across
/// the server chain — mirrors the Android ApiClient pinning. Disabled while pins is empty.
final class PinningDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        guard SecTrustEvaluateWithError(trust, nil) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        if InVpnConfig.pins.isEmpty {
            return (.useCredential, URLCredential(trust: trust))
        }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        for cert in chain {
            if let pin = Self.spkiPin(cert), InVpnConfig.pins.contains(pin) {
                return (.useCredential, URLCredential(trust: trust))
            }
        }
        return (.cancelAuthenticationChallenge, nil)
    }

    /// base64(SHA256(DER SubjectPublicKeyInfo)). TODO: prepend the key-type ASN.1 header to the raw
    /// key from SecKeyCopyExternalRepresentation so this matches Android's cert.publicKey.encoded pin.
    static func spkiPin(_ cert: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(cert),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return Crypto.sha256Base64(raw) // placeholder until SPKI header wrapping is added
    }
}
