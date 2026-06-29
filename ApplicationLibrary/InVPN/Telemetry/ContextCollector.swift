import Foundation
import Library
import Network
#if os(iOS)
    import NetworkExtension
#endif
#if os(macOS)
    import CoreWLAN
#endif
#if os(iOS) || os(tvOS)
    import DeviceKit
#endif
#if canImport(Libbox)
    import Libbox
#endif

// MARK: - ContextCollector

/// Collects device and network context for telemetry events.
///
/// Owns a long-lived `NWPathMonitor` started on a background queue at init.
/// Thread-safe: the latest `NWPath` is cached behind an `NSLock`.
///
/// Usage:
/// - `networkSnapshot()` — sync, best-effort (no SSID/BSSID; those need async permission check on iOS).
/// - `networkSnapshotAsync()` — async, attempts to fill SSID/BSSID.
/// - `appInfo()`, `deviceModel()`, `osVersion()`, `coreVersion()` — metadata accessors.
public final class ContextCollector: @unchecked Sendable {

    // MARK: - Path monitor

    private let monitor = NWPathMonitor()
    private let lock    = NSLock()
    private var _latestPath: Network.NWPath?

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self._latestPath = path
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "net.invpn.ContextCollector", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - Private helpers

    private var latestPath: Network.NWPath? {
        lock.lock()
        defer { lock.unlock() }
        return _latestPath
    }

    /// Map NWPath to a canonical network-type string.
    /// Prefers `availableInterfaces.first?.type` (mirrors ExtensionPlatformInterface),
    /// falls back to `usesInterfaceType` queries.
    private func networkType(for path: Network.NWPath) -> String {
        if let first = path.availableInterfaces.first {
            switch first.type {
            case .wifi:          return "wifi"
            case .cellular:      return "cellular"
            case .wiredEthernet: return "ethernet"
            default:             break
            }
        }
        if path.usesInterfaceType(.wifi)          { return "wifi" }
        if path.usesInterfaceType(.cellular)      { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "ethernet" }
        return "other"
    }

    // MARK: - Network snapshots

    /// Synchronous network snapshot.
    ///
    /// Fills `type`, `expensive`, and `constrained` from the cached `NWPath`.
    /// `ssid`, `bssid`, `carrier`, `mcc_mnc`, and `mtu` are left nil
    /// (SSID requires an async permission check on iOS — call `networkSnapshotAsync()` instead).
    public func networkSnapshot() -> NetContext {
        guard let path = latestPath, path.status != .unsatisfied else {
            return NetContext(type: "other")
        }
        return NetContext(
            type:        networkType(for: path),
            expensive:   path.isExpensive,
            constrained: path.isConstrained
        )
    }

    /// Async network snapshot that attempts to resolve SSID and BSSID.
    ///
    /// Starts from `networkSnapshot()` and overlays:
    /// - **iOS**: `NEHotspotNetwork.fetchCurrent()` (requires "Access WiFi Information"
    ///   entitlement + location permission — returns nil gracefully when unavailable or denied).
    /// - **macOS**: `CWWiFiClient.shared().interface()` — may be nil on non-Wi-Fi hardware.
    ///
    /// Returns a complete `NetContext`; SSID/BSSID remain nil on any failure.
    public func networkSnapshotAsync() async -> NetContext {
        var ctx = networkSnapshot()
        #if os(iOS)
        // NEHotspotNetwork.fetchCurrent() returns nil when:
        //   - "Access WiFi Information" entitlement is missing,
        //   - location permission is not granted,
        //   - not connected to Wi-Fi.
        // No crash in any of these cases.
        if let hotspot = await NEHotspotNetwork.fetchCurrent() {
            ctx.ssid  = hotspot.ssid.isEmpty  ? nil : hotspot.ssid
            ctx.bssid = hotspot.bssid.isEmpty ? nil : hotspot.bssid
        }
        #elseif os(macOS)
        let iface = CWWiFiClient.shared().interface()
        ctx.ssid  = iface?.ssid()
        ctx.bssid = iface?.bssid()
        #endif
        return ctx
    }

    // MARK: - App info

    /// App version/platform metadata suitable for a `TelemetryEvent.app` field.
    public func appInfo() -> AppInfo {
        #if os(iOS) || os(tvOS)
        let platform = "ios"
        #elseif os(macOS)
        let platform = "macos"
        #else
        let platform = "unknown"
        #endif
        return AppInfo(ver: Bundle.main.version, platform: platform)
    }

    // MARK: - Device model

    /// Human-readable device model string.
    ///
    /// - iOS/tvOS: `Device.current.safeDescription` via DeviceKit.
    /// - macOS: `hw.model` sysctlbyname, e.g. `"MacBookPro18,1"`.
    /// - Returns nil on any failure.
    public func deviceModel() -> String? {
        #if os(iOS) || os(tvOS)
        return Device.current.safeDescription
        #elseif os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
        #else
        return nil
        #endif
    }

    // MARK: - OS version

    /// Human-readable OS version string, e.g. `"iOS 17.5"` / `"macOS 14.5"`.
    public func osVersion() -> String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    // MARK: - Core version

    /// sing-box core version string (e.g. `"1.11.0-beta.1"`).
    ///
    /// Returns nil when Libbox is not linked (test / stub builds).
    /// Wraps `LibboxVersion()` defensively via `canImport(Libbox)`.
    public func coreVersion() -> String? {
        #if canImport(Libbox)
        return LibboxVersion()
        #else
        return nil
        #endif
    }
}
