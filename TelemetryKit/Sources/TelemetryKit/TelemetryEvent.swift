import Foundation

// MARK: - Trigger

/// Wire trigger values — raw strings match §4.3 JSON schema exactly.
public enum Trigger: String, Codable, Sendable {
    case connectAttempt     = "connect_attempt"
    case connectSuccess     = "connect_success"
    case connectFail        = "connect_fail"
    case disconnect         = "disconnect"
    case failover           = "failover"
    case degradation        = "degradation"
    case netChange          = "net_change"
    case captivePortal      = "captive_portal"
    case pmtuSuspect        = "pmtu_suspect"
    case heartbeat          = "heartbeat"
    case urltestResult      = "urltest_result"
    case appStart           = "app_start"
    case appUpdate          = "app_update"
    case crash              = "crash"
    case permDenied         = "perm_denied"
    case userAction         = "user_action"
    case complaint          = "complaint"
}

// MARK: - FailPhase

/// Connection failure phase — raw strings match §4.3 JSON schema exactly.
public enum FailPhase: String, Codable, Sendable {
    case dns                 = "dns"
    case tcpConnect          = "tcp_connect"
    case tlsRealityHandshake = "tls_reality_handshake"
    case timeout             = "timeout"
    case authReject          = "auth_reject"
    case noInternet          = "no_internet"
}

// MARK: - NetContext

/// Network context attached to an event.
///
/// JSON keys: type, carrier, mcc_mnc, ssid, bssid, mtu.
/// Nil optionals are OMITTED from JSON (synthesised `encodeIfPresent`).
public struct NetContext: Codable, Sendable {
    public var type: String
    public var carrier: String?
    public var mccMnc: String?
    public var ssid: String?
    public var bssid: String?
    public var mtu: Int?

    public init(
        type: String,
        carrier: String? = nil,
        mccMnc: String? = nil,
        ssid: String? = nil,
        bssid: String? = nil,
        mtu: Int? = nil
    ) {
        self.type    = type
        self.carrier = carrier
        self.mccMnc  = mccMnc
        self.ssid    = ssid
        self.bssid   = bssid
        self.mtu     = mtu
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case carrier
        case mccMnc  = "mcc_mnc"
        case ssid
        case bssid
        case mtu
    }
}

// MARK: - ConnInfo

/// VPN connection details attached to an event.
///
/// JSON keys: node, sni, proto, fail_phase, error_code, error_text, ttc_ms, rtt_ms, loss.
/// Nil optionals are OMITTED from JSON (synthesised `encodeIfPresent`).
public struct ConnInfo: Codable, Sendable {
    public var node: String?
    public var sni: String?
    public var proto: String?
    public var failPhase: FailPhase?
    public var errorCode: String?
    public var errorText: String?
    public var ttcMs: Int?
    public var rttMs: Int?
    public var loss: Double?

    public init(
        node: String? = nil,
        sni: String? = nil,
        proto: String? = nil,
        failPhase: FailPhase? = nil,
        errorCode: String? = nil,
        errorText: String? = nil,
        ttcMs: Int? = nil,
        rttMs: Int? = nil,
        loss: Double? = nil
    ) {
        self.node      = node
        self.sni       = sni
        self.proto     = proto
        self.failPhase = failPhase
        self.errorCode = errorCode
        self.errorText = errorText
        self.ttcMs     = ttcMs
        self.rttMs     = rttMs
        self.loss      = loss
    }

    private enum CodingKeys: String, CodingKey {
        case node
        case sni
        case proto
        case failPhase  = "fail_phase"
        case errorCode  = "error_code"
        case errorText  = "error_text"
        case ttcMs      = "ttc_ms"
        case rttMs      = "rtt_ms"
        case loss
    }
}

// MARK: - AppInfo

/// App version/platform metadata.
///
/// JSON keys: ver, platform.  No optional fields; no CodingKeys needed.
public struct AppInfo: Codable, Sendable {
    public var ver: String
    public var platform: String

    public init(ver: String, platform: String) {
        self.ver      = ver
        self.platform = platform
    }
}

// MARK: - TelemetryEvent

/// A single telemetry event.
///
/// JSON keys: ts, trigger, device_id, account, net, conn, app, log_tail.
/// Nil optionals are OMITTED from JSON (synthesised `encodeIfPresent`).
public struct TelemetryEvent: Codable, Sendable {
    /// ISO8601 timestamp string, e.g. "2026-06-29T12:00:00Z".
    public var ts: String
    public var trigger: Trigger
    public var deviceId: String
    public var account: String?
    public var net: NetContext?
    public var conn: ConnInfo?
    public var app: AppInfo?
    public var logTail: [String]?

    public init(
        ts: String,
        trigger: Trigger,
        deviceId: String,
        account: String? = nil,
        net: NetContext? = nil,
        conn: ConnInfo? = nil,
        app: AppInfo? = nil,
        logTail: [String]? = nil
    ) {
        self.ts       = ts
        self.trigger  = trigger
        self.deviceId = deviceId
        self.account  = account
        self.net      = net
        self.conn     = conn
        self.app      = app
        self.logTail  = logTail
    }

    private enum CodingKeys: String, CodingKey {
        case ts
        case trigger
        case deviceId = "device_id"
        case account
        case net
        case conn
        case app
        case logTail  = "log_tail"
    }
}

// MARK: - TelemetryBatch

/// A batch of events to be sealed and uploaded.
///
/// JSON keys: schema, device_id, sent_at, events.
/// Nil `sentAt` is OMITTED from JSON (synthesised `encodeIfPresent`).
public struct TelemetryBatch: Codable, Sendable {
    public var schema: Int
    public var deviceId: String
    public var sentAt: String?
    public var events: [TelemetryEvent]

    public init(
        schema: Int = 1,
        deviceId: String,
        sentAt: String? = nil,
        events: [TelemetryEvent]
    ) {
        self.schema   = schema
        self.deviceId = deviceId
        self.sentAt   = sentAt
        self.events   = events
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case deviceId = "device_id"
        case sentAt   = "sent_at"
        case events
    }

    /// Encode the batch to deterministic (sorted-keys) JSON bytes.
    public func toJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
