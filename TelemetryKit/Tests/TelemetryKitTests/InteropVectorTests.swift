import XCTest
import CryptoKit
@testable import TelemetryKit

// MARK: - Interop vector types

private struct VectorEvent: Codable {
    let trigger: String
    let ts: String
    let device_id: String
}

private struct VectorBatch: Codable {
    let schema: Int
    let device_id: String
    let events: [VectorEvent]
}

private struct VectorEnvelope: Decodable {
    let v: Int
    let alg: String
    let nonce: String
    let ct: String
}

private struct InteropVector: Decodable {
    let device_token: String
    let key_hex: String
    let batch: VectorBatch
    let plaintext_sha256: String
    let env: VectorEnvelope
}

// MARK: - Test suite

final class InteropVectorTests: XCTestCase {

    private var vector: InteropVector!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "interop_vector", withExtension: "json"),
            "interop_vector.json not found in test bundle"
        )
        let data = try Data(contentsOf: url)
        vector = try JSONDecoder().decode(InteropVector.self, from: data)
    }

    // MARK: Test 1 — Key derivation matches frozen vector

    func testDeriveKeyMatchesVector() {
        let key = TelemetryCrypto.deriveKey(vector.device_token)
        let keyHex = key.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(
            keyHex,
            vector.key_hex,
            "HKDF-SHA256 derived key does not match vector.key_hex"
        )
    }

    // MARK: Test 2 — Open frozen backend-produced envelope

    func testOpenFrozenVector() throws {
        // Re-encode the envelope struct back to JSON so open() can parse it
        let envDict: [String: Any] = [
            "v":     vector.env.v,
            "alg":   vector.env.alg,
            "nonce": vector.env.nonce,
            "ct":    vector.env.ct,
        ]
        let envJSON = try JSONSerialization.data(withJSONObject: envDict)

        let plaintext = try TelemetryCrypto.open(token: vector.device_token, envelopeJSON: envJSON)

        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
            "decrypted plaintext is not a JSON object"
        )

        XCTAssertEqual(
            parsed["device_id"] as? String,
            "interop-device-1",
            "batch.device_id mismatch"
        )

        let events = try XCTUnwrap(
            parsed["events"] as? [[String: Any]],
            "batch.events missing or wrong type"
        )
        XCTAssertFalse(events.isEmpty, "batch.events is empty")

        let first = try XCTUnwrap(events.first)
        XCTAssertEqual(first["trigger"] as? String, "heartbeat", "event trigger mismatch")
        XCTAssertEqual(first["ts"] as? String, "2026-06-29T12:00:00Z", "event ts mismatch")
    }

    // MARK: Test 3 — Seal / Open round-trip (proves gzip + GCM self-consistency)

    func testSealOpenRoundtrip() throws {
        // Fixed-content plaintext so byte comparison is deterministic
        let sampleJSON = #"{"device_id":"rt-device","schema":1,"events":[{"trigger":"heartbeat","ts":"2026-01-01T00:00:00Z","device_id":"rt-device"}]}"#
        let sampleData = Data(sampleJSON.utf8)
        let token = "roundtrip-test-token"

        let envelope  = try TelemetryCrypto.seal(plaintext: sampleData, token: token)
        let recovered = try TelemetryCrypto.open(token: token, envelopeJSON: envelope)

        XCTAssertEqual(recovered, sampleData, "round-trip: recovered bytes differ from original")
    }

    // MARK: Test 4 — Emit deterministic envelope for Python backend cross-check

    /// Seals vector.batch with a 12-zero-byte nonce and prints the envelope.
    /// The controller feeds CROSSCHECK_ENVELOPE to the Python backend's decrypt_batch.
    func testEmitSealForBackendCrosscheck() throws {
        // Encode the batch deterministically (sorted keys so the Python side can reproduce)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let batchData = try encoder.encode(vector.batch)

        let zeroNonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 12))
        let key       = TelemetryCrypto.deriveKey(vector.device_token)
        let envelope  = try TelemetryCrypto.sealWithKey(
            plaintext: batchData,
            key:       key,
            nonce:     zeroNonce
        )

        let envelopeStr = try XCTUnwrap(
            String(data: envelope, encoding: .utf8),
            "envelope is not valid UTF-8"
        )
        // Controller scrapes this line from the test log
        print("CROSSCHECK_ENVELOPE=\(envelopeStr)")

        // Also verify the envelope decrypts correctly within Swift
        let recovered = try TelemetryCrypto.open(token: vector.device_token, envelopeJSON: envelope)

        let recoveredObj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: recovered) as? [String: Any]
        )
        XCTAssertEqual(
            recoveredObj["device_id"] as? String,
            vector.batch.device_id,
            "crosscheck round-trip: device_id mismatch"
        )
        XCTAssertEqual(
            recoveredObj["schema"] as? Int,
            vector.batch.schema,
            "crosscheck round-trip: schema mismatch"
        )
    }
}
