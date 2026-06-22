import Foundation
import CryptoKit
import CommonCrypto

/// InVPN config-delivery crypto — mirrors Android `invpn/Crypto.kt` and the Python backend
/// (`vpn-config-api`). Contract (must match byte-for-byte):
///   body_key = PBKDF2-HMAC-SHA256(utf8(password), salt_body, 210000, 32 bytes)
///   config   = AES-256-GCM(body_key, nonce=12B, ct=ciphertext||tag(16B), aad=none)
///   wire encoding = URL-safe base64, no padding
/// body_key never crosses the wire (only the password does, once, at login).
enum Crypto {
    static let pbkdf2Iters = 210_000

    enum CryptoError: Error { case decode, decrypt }

    /// URL-safe base64 decode, tolerant of missing padding / whitespace.
    static func b64UrlDecode(_ s: String) throws -> Data {
        var t = s.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        t = String(t.prefix { $0 != "=" })
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t) else { throw CryptoError.decode }
        return d
    }

    /// URL-safe base64 encode, no padding.
    static func b64UrlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// PBKDF2-HMAC-SHA256 over the raw UTF-8 password bytes → 32-byte key
    /// (CommonCrypto; byte-exact with Python's hashlib.pbkdf2_hmac and the Android port).
    static func deriveBodyKey(password: String, salt: Data, iterations: Int = pbkdf2Iters) -> Data {
        let pw = Array(password.utf8)
        let saltBytes = [UInt8](salt)
        var out = [UInt8](repeating: 0, count: 32)
        _ = pw.withUnsafeBufferPointer { pwPtr in
            saltBytes.withUnsafeBufferPointer { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr.baseAddress, pw.count,
                    saltPtr.baseAddress, saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &out, out.count
                )
            }
        }
        return Data(out)
    }

    /// AES-256-GCM decrypt. `ctWithTag` is ciphertext with the 16-byte tag appended.
    static func aesGcmDecrypt(key: Data, nonce: Data, ctWithTag: Data) throws -> Data {
        guard ctWithTag.count >= 16 else { throw CryptoError.decrypt }
        let ct = ctWithTag.prefix(ctWithTag.count - 16)
        let tag = ctWithTag.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    /// Decrypt a /config response body with an already-derived body key.
    static func decryptWithBodyKey(_ bodyKey: Data, nonceB64: String, ctB64: String) throws -> Data {
        try aesGcmDecrypt(key: bodyKey,
                          nonce: try b64UrlDecode(nonceB64),
                          ctWithTag: try b64UrlDecode(ctB64))
    }

    /// base64(SHA-256(data)) — standard base64; used for SPKI pin comparison.
    static func sha256Base64(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }
}
