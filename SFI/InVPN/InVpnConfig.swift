import Foundation

/// InVPN deployment constants — mirrors Android `invpn/InVpnConfig.kt`. Same backend + pins.
enum InVpnConfig {
    static let apiBase = "https://ofjnb.net"

    /// SPKI SHA-256 pins (standard base64) for ofjnb.net — leaf + Let's Encrypt intermediate
    /// (renewal-safe) + cross-signed root backstop, matching the Android InVpnConfig.PINS.
    ///
    /// NOTE: kept EMPTY for the first iOS build. iOS SPKI computation must hash the full DER
    /// SubjectPublicKeyInfo (SecKeyCopyExternalRepresentation returns the *raw* key, so a key-type
    /// ASN.1 header must be prepended to match the Android pins). Enable only after verifying the
    /// computed pins on-device — a wrong pin bricks all backend access. See ApiClient.PinningDelegate.
    static let pins: Set<String> = []

    /// Reference values (do NOT enable until on-device verified):
    ///   leaf:         zRFPPXTDpTUwB+MiZbHezW/i1jzpgyO9t2Gw+zkeaVQ=
    ///   intermediate: nWN7PSep5XDQdge5zK24CnCRXHr3KvzhKEGxsdqCX9E=
    ///   root backstop: fk6IOKit1ild5647BH06ujSIq5XbCgqlbYl6ANhhi88=

    /// Single managed profile name created from the fetched config.
    static let managedProfileName = "InVPN"
}
