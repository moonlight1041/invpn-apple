import Foundation
import GRDB

// MARK: - Telemetry event buffer backed by the shared app-group DB.
//
// The `telemetry_events` table is created by the "add_telemetry_buffer" migration
// registered in Library/Database/Database.swift.
//
// All functions follow the RemoteServerManager pattern:
//   nonisolated static async throws + Database.sharedWriter.write/read { db in … }
// Raw SQL (db.execute / Row.fetchAll / Int.fetchOne) matches the
// "use_relative_profile_paths" + "fix_cellular_typo" migration style.

public enum TelemetryStore {

    // MARK: - Write

    /// Append one serialised-JSON event payload to the FIFO buffer.
    ///
    /// - Parameters:
    ///   - payload: One event encoded as a JSON string.
    ///   - ts:      Insertion timestamp (Unix seconds, e.g. `Date().timeIntervalSince1970`).
    public nonisolated static func insert(payload: String, ts: Double) async throws {
        try await Database.sharedWriter.write { db in
            try db.execute(
                sql: "INSERT INTO telemetry_events (ts, payload, attempts) VALUES (?, ?, 0)",
                arguments: [ts, payload]
            )
        }
    }

    /// Remove rows whose primary keys appear in `ids`. No-op for an empty slice.
    public nonisolated static func delete(ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try await Database.sharedWriter.write { db in
            try db.execute(
                sql: "DELETE FROM telemetry_events WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
        }
    }

    /// Increment the delivery-attempt counter for each row in `ids`. No-op for an empty slice.
    public nonisolated static func incrementAttempts(ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try await Database.sharedWriter.write { db in
            try db.execute(
                sql: "UPDATE telemetry_events SET attempts = attempts + 1 WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
        }
    }

    /// Ring-buffer trim: if the row count exceeds `max`, delete the oldest (count − max) rows.
    ///
    /// The check and delete are performed in a single write transaction to avoid TOCTOU races.
    public nonisolated static func trimTo(_ max: Int) async throws {
        try await Database.sharedWriter.write { db in
            let current = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry_events") ?? 0
            let overflow = current - max
            guard overflow > 0 else { return }
            try db.execute(
                sql: """
                    DELETE FROM telemetry_events
                    WHERE id IN (
                        SELECT id FROM telemetry_events ORDER BY id ASC LIMIT ?
                    )
                    """,
                arguments: [overflow]
            )
        }
    }

    // MARK: - Read

    /// Return the oldest `limit` events in FIFO order (ORDER BY id ASC).
    public nonisolated static func oldestBatch(_ limit: Int) async throws -> [(id: Int64, payload: String)] {
        try await Database.sharedWriter.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, payload FROM telemetry_events ORDER BY id ASC LIMIT ?",
                arguments: [limit]
            )
            return rows.map { (id: $0["id"], payload: $0["payload"]) }
        }
    }

    /// Current row count.
    public nonisolated static func count() async throws -> Int {
        try await Database.sharedWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry_events") ?? 0
        }
    }
}
