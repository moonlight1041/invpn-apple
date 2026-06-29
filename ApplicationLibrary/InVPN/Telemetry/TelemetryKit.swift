import Foundation

// MARK: - TelemetryCrypto + Batch convenience

extension TelemetryCrypto {

    /// Encode and seal a `TelemetryBatch` in one call.
    ///
    /// Equivalent to `TelemetryCrypto.seal(plaintext: batch.toJSONData(), token: token)`.
    ///
    /// - Parameters:
    ///   - batch: The batch to encode (JSON, sorted keys) then AES-256-GCM-seal.
    ///   - token: Device token used to derive the HKDF key.
    /// - Returns: Envelope JSON as UTF-8 `Data` — suitable for direct upload.
    public static func sealBatch(_ batch: TelemetryBatch, token: String) throws -> Data {
        let json = try batch.toJSONData()
        return try seal(plaintext: json, token: token)
    }
}
