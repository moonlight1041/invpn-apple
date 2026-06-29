import Foundation
import Library

// MARK: - ContextCollector shared singleton

extension ContextCollector {
    /// Process-wide singleton. Starts the NWPathMonitor at first access.
    public static let shared = ContextCollector()
}

// MARK: - Telemetry facade

/// Consent-gated, fire-and-forget telemetry facade.
///
/// - Consent gate: no-op unless `SharedPreferences.telemetryConsentGiven` is true.
/// - Login gate:   no-op unless `SecureStore.load()` returns credentials.
/// - Non-blocking: `record()` is async and never propagates errors.
/// - Thread-safe:  all I/O goes through GRDB async writers.
///
/// ## Lifecycle
/// Call `Telemetry.installHooks()` once from the main-app entry point after
/// the user has granted consent (B.7 wires this). Until then, every hook call
/// is a no-op (consent gate returns early).
public enum Telemetry {

    // MARK: - ISO 8601 formatter (reused; configured once at init)

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Flush handler (B.6 sets this)

    /// B.6 sets this to upload pending events to the server.
    /// `flushNow()` is a no-op until it is set.
    public static var flushHandler: (() async -> Void)?

    // MARK: - record

    /// Record a telemetry event.
    ///
    /// No-op if consent has not been granted or the user is not logged in.
    /// All errors are silently discarded; this function never throws.
    public static func record(_ trigger: Trigger, conn: ConnInfo? = nil) async {
        // 1. Consent gate
        guard await SharedPreferences.telemetryConsentGiven.get() else { return }
        // 2. Login gate
        guard let creds = SecureStore.load() else { return }
        // 3. Stable per-device ID (lazily initialised, survives logout)
        let deviceId = await resolveDeviceId()
        // 4. Build event
        let now = Date()
        let ts = iso.string(from: now)
        let net = ContextCollector.shared.networkSnapshot()
        let app = ContextCollector.shared.appInfo()
        let event = TelemetryEvent(
            ts: ts,
            trigger: trigger,
            deviceId: deviceId,
            account: creds.username,
            net: net,
            conn: conn,
            app: app
        )
        // 5. Encode → store
        guard let jsonData = try? JSONEncoder().encode(event),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        try? await TelemetryStore.insert(payload: jsonString, ts: now.timeIntervalSince1970)
        // 6. Ring-buffer cap: keep at most 2 000 events
        try? await TelemetryStore.trimTo(2000)
        // 7. Flush immediately on high-priority triggers
        if trigger == .connectFail || trigger == .degradation || trigger == .complaint {
            await flushNow()
        }
    }

    // MARK: - flushNow

    /// Forward to the upload handler registered by B.6.  No-op until B.6 sets it.
    public static func flushNow() async {
        await flushHandler?()
    }

    // MARK: - installHooks

    /// Wire the Library-layer tunnel hooks to `Telemetry.record`.
    ///
    /// Call once from the main-app entry point (e.g. `InVpnRootView.onAppear`).
    /// Safe to call multiple times — the hooks are simply overwritten.
    ///
    /// Implementation note: Library cannot import ApplicationLibrary (circular
    /// dependency), so `CommandClient` and `ExtensionPlatformInterface` expose
    /// plain `(@Sendable …) -> Void` static vars.  This function sets them.
    public static func installHooks() {
        // B.6 — register the flusher so high-priority events and foreground wake-up
        // trigger an upload of buffered events.
        flushHandler = { await TelemetryClient.shared.flush() }

        // connect_success — command channel to the NE came up
        CommandClient.telemetryOnConnected = {
            Task { await record(.connectSuccess) }
        }

        // disconnect — command channel closed (clean teardown)
        CommandClient.telemetryOnDisconnected = {
            Task { await record(.disconnect) }
        }

        // connect_fail — a ConnectionError was created
        // .connectFailed  → initial handshake never completed  → failPhase: timeout
        // .connectionLost → established connection dropped      → failPhase: no_internet
        CommandClient.telemetryOnConnectionError = { kind, message in
            let phase: FailPhase = (kind == .connectFailed) ? .timeout : .noInternet
            Task {
                await record(.connectFail, conn: ConnInfo(failPhase: phase, errorText: message))
            }
        }

        // degradation — interesting error keywords in the tunnel log
        // Only fires when ApplicationLibrary is loaded (main-app process);
        // always nil in the NE process where only Library is linked.
        ExtensionPlatformInterface.telemetryOnLog = { message in
            let lower = message.lowercased()
            guard lower.contains("reality")
                || lower.contains("handshake failed")
                || lower.contains("timeout")
                || lower.contains("connection reset") else { return }
            Task { await record(.degradation, conn: ConnInfo(errorText: message)) }
        }
    }

    // MARK: - Private helpers

    /// Return the persisted device ID, creating one on first call.
    private static func resolveDeviceId() async -> String {
        let stored = await SharedPreferences.telemetryDeviceId.get()
        if !stored.isEmpty { return stored }
        let newId = UUID().uuidString
        await SharedPreferences.telemetryDeviceId.set(newId)
        return newId
    }
}
