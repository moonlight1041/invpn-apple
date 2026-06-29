import Foundation
import CryptoKit

// MARK: - Error type

/// Errors thrown by TelemetryCrypto and the Gzip helper.
public enum TelemetryCryptoError: Error {
    /// Base64url or JSON decode failure.
    case decode
    /// AES-GCM encryption failure.
    case encrypt
    /// AES-GCM decryption failure (wrong key / corrupted ciphertext).
    case decrypt
    /// Gzip compress/decompress failure.
    case gzip
}

// MARK: - TelemetryCrypto

/// INVPN telemetry crypto — pure Swift, no external dependencies.
///
/// Contract (byte-exact with the Python vpn-config-api backend and Android TelemetryCrypto.kt):
///
///   key     = HKDF-SHA256(ikm=utf8(deviceToken), salt="invpn-telemetry", info="v1", L=32)
///   gzipped = gzip(utf8(batchJSON))          ← RFC 1952, raw DEFLATE inside
///   ct      = AES-256-GCM(key, nonce12B, gzipped).ciphertext ++ .tag   (NOT .combined)
///   envelope = {"v":1,"alg":"AES-256-GCM","nonce":<b64url(nonce)>,"ct":<b64url(ct)>}
///
/// b64url: URL-safe base64 (`+`→`-`, `/`→`_`), no padding.
public enum TelemetryCrypto {

    // MARK: - Key derivation

    /// Derive the 32-byte telemetry symmetric key from the device token.
    /// HKDF-SHA256(ikm=utf8(token), salt="invpn-telemetry", info="v1", outputByteCount=32).
    public static func deriveKey(_ deviceToken: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(deviceToken.utf8)),
            salt: Data("invpn-telemetry".utf8),
            info: Data("v1".utf8),
            outputByteCount: 32
        )
    }

    // MARK: - Seal (encrypt)

    /// Gzip-compress `plaintext` (JSON bytes) and AES-256-GCM encrypt with a random nonce.
    ///
    /// - Parameters:
    ///   - plaintext: UTF-8 encoded JSON batch bytes.
    ///   - token: Device token used to derive the key.
    /// - Returns: Envelope JSON as UTF-8 `Data`:
    ///   `{"alg":"AES-256-GCM","ct":"<b64url>","nonce":"<b64url>","v":1}`
    public static func seal(plaintext: Data, token: String) throws -> Data {
        let key = deriveKey(token)
        let nonce = AES.GCM.Nonce()          // 12 cryptographically-random bytes
        return try sealWithKey(plaintext: plaintext, key: key, nonce: nonce)
    }

    /// Seal with an explicit nonce.  Internal; used by tests for deterministic vectors.
    static func sealWithKey(
        plaintext: Data,
        key: SymmetricKey,
        nonce: AES.GCM.Nonce
    ) throws -> Data {
        let gzipped = try Gzip.gzip(plaintext)

        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.seal(gzipped, using: key, nonce: nonce)
        } catch {
            throw TelemetryCryptoError.encrypt
        }

        // ct = ciphertext || tag(16B)  — NOT .combined which prepends the 12-byte nonce
        var ct = Data(box.ciphertext)
        ct.append(contentsOf: box.tag)

        // Nonce as Data (12 bytes)
        let nonceData = nonce.withUnsafeBytes { Data($0) }

        let envelope: [String: Any] = [
            "v":     1,
            "alg":   "AES-256-GCM",
            "nonce": b64urlEncode(nonceData),
            "ct":    b64urlEncode(ct),
        ]
        // .sortedKeys → deterministic JSON key order (alg/ct/nonce/v)
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    // MARK: - Open (decrypt)

    /// Decrypt an envelope JSON and return the gunzipped plaintext JSON bytes.
    ///
    /// - Parameters:
    ///   - token: Device token used to derive the key.
    ///   - envelopeJSON: JSON produced by `seal` or the Python backend.
    /// - Returns: Original plaintext (UTF-8 JSON batch bytes).
    public static func open(token: String, envelopeJSON: Data) throws -> Data {
        guard
            let obj       = try? JSONSerialization.jsonObject(with: envelopeJSON) as? [String: Any],
            let nonceStr  = obj["nonce"] as? String,
            let ctStr     = obj["ct"]    as? String
        else { throw TelemetryCryptoError.decode }

        let nonceData = try b64urlDecode(nonceStr)
        let ctData    = try b64urlDecode(ctStr)
        guard ctData.count >= 16 else { throw TelemetryCryptoError.decrypt }

        let ciphertext = ctData.prefix(ctData.count - 16)
        let tag        = ctData.suffix(16)

        let key = deriveKey(token)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(
                nonce:      try AES.GCM.Nonce(data: nonceData),
                ciphertext: ciphertext,
                tag:        tag
            )
        } catch {
            throw TelemetryCryptoError.decode
        }

        let gzipped: Data
        do {
            gzipped = try AES.GCM.open(box, using: key)
        } catch {
            throw TelemetryCryptoError.decrypt
        }

        return try Gzip.gunzip(gzipped)
    }

    // MARK: - b64url helpers (internal; exposed via @testable for tests)

    /// URL-safe base64 encode, no padding.
    static func b64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// URL-safe base64 decode, tolerant of missing padding.
    static func b64urlDecode(_ s: String) throws -> Data {
        var t = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t) else { throw TelemetryCryptoError.decode }
        return d
    }
}
