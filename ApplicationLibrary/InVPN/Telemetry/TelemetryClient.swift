import Foundation

/// Upload flusher for the INVPN telemetry buffer.
///
/// Reads the oldest buffered events (up to 256 rows / 128 KB aggregate payload),
/// seals them with ``TelemetryCrypto``, and POSTs the envelope to `/t/v1/events`
/// via ``ApiClient``.
///
/// - HTTP 200  → delete the successfully delivered rows.
/// - non-200   → increment attempt counter; ring-buffer `trimTo(2000)` in
///               ``Telemetry.record(_:conn:)`` handles eventual eviction.
/// - Transport → status 0; rows are retried on the next flush call.
///
/// ``flush()`` is best-effort and never throws.  Wire it via
/// ``Telemetry.installHooks()`` so it is called on high-priority triggers and
/// when the app returns to the foreground.
public final class TelemetryClient {

    // MARK: - Singleton

    public static let shared = TelemetryClient()
    private init() {}

    // MARK: - Constants

    /// Maximum aggregate UTF-8 bytes of stored payloads per flush call.
    private static let maxBatchBytes = 128 * 1024   // 128 KB
    /// Maximum number of rows per flush call (also the GRDB LIMIT).
    private static let maxEvents = 256

    // MARK: - Public API

    /// Upload pending telemetry events. Best-effort — never throws.
    public func flush() async {
        do {
            try await _flush()
        } catch {
            // Intentionally swallowed: telemetry must never crash or block the caller.
        }
    }

    // MARK: - Implementation

    private func _flush() async throws {

        // 1. Login gate — device token is the HKDF key material + Authorization header.
        guard let creds = SecureStore.load() else { return }
        let token = creds.deviceToken

        // 2. Read the oldest batch from the FIFO buffer.
        let allRows = try await TelemetryStore.oldestBatch(Self.maxEvents)
        guard !allRows.isEmpty else { return }

        // 3. Enforce 128 KB aggregate payload cap (take a prefix that fits).
        var rows: [(id: Int64, payload: String)] = []
        var totalBytes = 0
        for row in allRows {
            let size = row.payload.utf8.count
            guard totalBytes + size <= Self.maxBatchBytes else { break }
            rows.append(row)
            totalBytes += size
        }
        guard !rows.isEmpty else { return }

        // 4. Decode each stored JSON payload into TelemetryEvent.
        //    Rows that fail to decode are skipped (corrupt data); they will be
        //    evicted naturally by the ring-buffer trimTo.
        let decoder = JSONDecoder()
        var events: [TelemetryEvent] = []
        for row in rows {
            guard let data = row.payload.data(using: .utf8),
                  let event = try? decoder.decode(TelemetryEvent.self, from: data)
            else { continue }
            events.append(event)
        }
        guard !events.isEmpty else { return }

        // 5. Derive device ID from the first event (set by Telemetry.record at capture time).
        let deviceId = events.first?.deviceId ?? ""

        // 6. Assemble TelemetryBatch.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let batch = TelemetryBatch(
            schema:   1,
            deviceId: deviceId,
            sentAt:   iso.string(from: Date()),
            events:   events
        )

        // 7. Seal: gzip(JSON) → AES-256-GCM → envelope JSON bytes.
        let envelope = try TelemetryCrypto.sealBatch(batch, token: token)

        // 8. POST envelope to /t/v1/events.
        let code = await ApiClient.shared.postTelemetry(token: token, envelope: envelope)

        // 9. Bookkeeping.
        let ids = rows.map(\.id)
        if code == 200 {
            // Confirmed delivery: remove from buffer.
            try await TelemetryStore.delete(ids: ids)
        } else {
            // Retriable failure: bump attempt counter.
            // Eventual eviction is handled by the ring-buffer trimTo(2000) called
            // inside Telemetry.record — no per-row attempt cap needed here.
            try await TelemetryStore.incrementAttempts(ids: ids)
        }
    }
}
