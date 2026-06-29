import XCTest
import CryptoKit
@testable import TelemetryKit

final class EventModelTests: XCTestCase {

    // MARK: Test 1 — §4.3 JSON wire shape

    /// Verifies snake_case key names, nested object shapes, and nil-omission.
    func testEventJSONShape() throws {
        let event = TelemetryEvent(
            ts: "2026-06-29T12:00:00Z",
            trigger: .heartbeat,
            deviceId: "d1",
            net: NetContext(type: "wifi", ssid: "Home", mtu: 1200),
            conn: ConnInfo(failPhase: .tlsRealityHandshake, ttcMs: 843)
        )
        let batch = TelemetryBatch(schema: 1, deviceId: "d1", events: [event])
        let data = try batch.toJSONData()

        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "batch JSON is not a dictionary"
        )

        // Top-level keys must be present
        XCTAssertNotNil(obj["schema"],    "missing key: schema")
        XCTAssertNotNil(obj["device_id"], "missing key: device_id")
        XCTAssertNotNil(obj["events"],    "missing key: events")

        // Exactly one event
        let events = try XCTUnwrap(obj["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        let ev = try XCTUnwrap(events.first)

        // Trigger raw value
        XCTAssertEqual(ev["trigger"] as? String, "heartbeat", "trigger raw-value mismatch")

        // Net sub-object — key names and values
        let net = try XCTUnwrap(ev["net"] as? [String: Any], "ev.net missing or wrong type")
        XCTAssertEqual(net["type"] as? String, "wifi",  "net.type mismatch")
        XCTAssertEqual(net["ssid"] as? String, "Home",  "net.ssid mismatch")
        XCTAssertEqual(net["mtu"]  as? Int,    1200,    "net.mtu mismatch")

        // Conn sub-object — snake_case keys
        let conn = try XCTUnwrap(ev["conn"] as? [String: Any], "ev.conn missing or wrong type")
        XCTAssertEqual(conn["fail_phase"] as? String, "tls_reality_handshake", "conn.fail_phase mismatch")
        XCTAssertEqual(conn["ttc_ms"]     as? Int,    843,                     "conn.ttc_ms mismatch")

        // Nil fields must be ABSENT (not null)
        // account — nil top-level optional
        XCTAssertNil(ev["account"],   "ev.account should be absent, not null")
        // carrier — nil NetContext optional
        XCTAssertNil(net["carrier"],  "net.carrier should be absent, not null")
        // node — nil ConnInfo optional
        XCTAssertNil(conn["node"],    "conn.node should be absent, not null")
    }

    // MARK: Test 2 — Seal / Open round-trip via TelemetryBatch

    /// Proves sealBatch → open → JSONDecoder roundtrip preserves device_id and both triggers.
    func testBatchSealOpenRoundtrip() throws {
        let e1 = TelemetryEvent(ts: "2026-01-01T00:00:00Z", trigger: .heartbeat,   deviceId: "rt1")
        let e2 = TelemetryEvent(ts: "2026-01-01T00:01:00Z", trigger: .connectFail, deviceId: "rt1")
        let batch = TelemetryBatch(schema: 1, deviceId: "rt1", events: [e1, e2])

        let envelope = try TelemetryCrypto.sealBatch(batch, token: "tok")
        let plaintext = try TelemetryCrypto.open(token: "tok", envelopeJSON: envelope)
        let decoded = try JSONDecoder().decode(TelemetryBatch.self, from: plaintext)

        XCTAssertEqual(decoded.deviceId,         batch.deviceId,       "device_id mismatch after roundtrip")
        XCTAssertEqual(decoded.events.count,      2,                    "event count mismatch after roundtrip")
        XCTAssertEqual(decoded.events[0].trigger, Trigger.heartbeat,   "events[0].trigger mismatch")
        XCTAssertEqual(decoded.events[1].trigger, Trigger.connectFail, "events[1].trigger mismatch")
    }

    // MARK: Test 3 — Emit deterministic batch envelope for backend cross-check

    /// Seals a connect_fail batch with a 12-zero-byte nonce and prints for backend validation.
    /// Controller scrapes CROSSCHECK_BATCH_ENVELOPE= from the test log.
    func testEmitBatchEnvelopeForBackend() throws {
        let event = TelemetryEvent(
            ts: "2026-06-29T12:00:00Z",
            trigger: .connectFail,
            deviceId: "x1",
            net: NetContext(type: "wifi", ssid: "TestNet", mtu: 1280),
            conn: ConnInfo(failPhase: .tlsRealityHandshake)
        )
        let batch = TelemetryBatch(schema: 1, deviceId: "x1", events: [event])

        let zeroNonce = try AES.GCM.Nonce(data: Data(count: 12))
        let envelope = try TelemetryCrypto.sealWithKey(
            plaintext: batch.toJSONData(),
            key:       TelemetryCrypto.deriveKey("interop-token-v1"),
            nonce:     zeroNonce
        )

        let envelopeStr = try XCTUnwrap(
            String(data: envelope, encoding: .utf8),
            "envelope is not valid UTF-8"
        )
        // Controller scrapes this line from the test log
        print("CROSSCHECK_BATCH_ENVELOPE=\(envelopeStr)")

        // Verify it round-trips via open
        let recovered = try TelemetryCrypto.open(token: "interop-token-v1", envelopeJSON: envelope)
        let decoded = try JSONDecoder().decode(TelemetryBatch.self, from: recovered)

        XCTAssertEqual(decoded.deviceId,         "x1",                    "roundtrip device_id mismatch")
        XCTAssertEqual(decoded.events[0].trigger, Trigger.connectFail,    "roundtrip trigger mismatch")
    }
}
