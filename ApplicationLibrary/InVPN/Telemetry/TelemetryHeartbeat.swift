import Foundation

/// Repeating heartbeat that detects "connected but data stalls" — the Path-MTU
/// black-hole symptom that WiFi users experience (Task B.8 in the telemetry plan).
///
/// While the tunnel is believed connected, the heartbeat fires every 45 s.  Each tick
/// does a lightweight GET to `https://www.gstatic.com/generate_204` (expects HTTP 204)
/// through the default (tunnel) routing path with a 6 s timeout.
///
/// - **Failure** (timeout / network error / unexpected status): fires `.degradation`
///   with `failPhase: .noInternet`.  `.degradation` is flush-priority in
///   `Telemetry.record()` so the stall event is uploaded immediately — the primary
///   signal for the data-stall dashboard query.
/// - **Success**: emits `.heartbeat` once every 5 successful ticks (~4 min) to keep
///   event volume low while still confirming connectivity.
///
/// ## Lifecycle
/// `start()` is called from `Telemetry.installHooks()` on tunnel connected;
/// `stop()` on tunnel disconnect.  Both methods are synchronous and safe to call
/// from any thread or async context.
public final class TelemetryHeartbeat: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = TelemetryHeartbeat()
    private init() {}

    // MARK: - Constants

    private static let probeURL       = URL(string: "https://www.gstatic.com/generate_204")!
    /// Interval between probes (45 seconds).
    private static let intervalNs: UInt64 = 45 * 1_000_000_000
    /// Emit `.heartbeat` once every N successful probes.
    private static let heartbeatEvery: Int = 5

    // MARK: - Private state (protected by `lock`)

    private let lock = NSLock()
    private var _loopTask: Task<Void, Never>?

    // MARK: - Public API

    /// Start the heartbeat loop.  Cancels any previously running loop first.
    ///
    /// Safe to call from any thread or async context.  Fire-and-forget — does not block.
    public func start() {
        lock.lock()
        let old = _loopTask
        _loopTask = Task { await self.runLoop() }
        lock.unlock()
        old?.cancel()
    }

    /// Stop the heartbeat loop.  No-op if not running.
    ///
    /// Safe to call from any thread or async context.  Fire-and-forget — does not block.
    public func stop() {
        lock.lock()
        let task = _loopTask
        _loopTask = nil
        lock.unlock()
        task?.cancel()
    }

    // MARK: - Loop (private)

    private func runLoop() async {
        // One ephemeral URLSession per connected session — no cookies, no cache, short timeout.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 6
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var successCount = 0

        while !Task.isCancelled {
            // Sleep first: avoids probing immediately after connect, and lets
            // a fast connect → disconnect cancel cleanly without firing a probe.
            do {
                try await Task.sleep(nanoseconds: Self.intervalNs)
            } catch {
                break  // Task was cancelled during sleep — exit cleanly.
            }
            guard !Task.isCancelled else { break }

            do {
                let (_, response) = try await session.data(from: Self.probeURL)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1

                if (200...299).contains(code) {
                    // Probe succeeded — count towards the periodic heartbeat.
                    successCount += 1
                    if successCount % Self.heartbeatEvery == 0 {
                        await Telemetry.record(.heartbeat)
                    }
                } else {
                    // Tunnel is up but probe returned unexpected status (e.g. captive portal
                    // redirect or transparent proxy).  Treat as a data-stall signal.
                    await Telemetry.record(
                        .degradation,
                        conn: ConnInfo(
                            failPhase: .noInternet,
                            errorText: "heartbeat status \(code)"
                        )
                    )
                    successCount = 0
                }

            } catch {
                // Timeout or URLError while tunnel is believed connected → Path-MTU black hole.
                await Telemetry.record(
                    .degradation,
                    conn: ConnInfo(
                        failPhase: .noInternet,
                        errorText: "heartbeat unreachable: \(error)"
                    )
                )
                successCount = 0
            }
        }
    }
}
