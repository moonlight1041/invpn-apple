import Foundation

/// «Российские сервисы напрямую». iOS/macOS can't do per-app split tunneling (MDM-only), so the
/// Android Apps-tab equivalent here is route-based: RU geoip + geosite go to the `direct` outbound
/// via sing-box route rules injected into the fetched config. Best-effort — ConfigInstaller
/// re-validates the result and falls back to the unmodified config if injection produced anything
/// LibboxCheckConfig rejects, so this can never break the tunnel.
enum RouteSplit {
    private static let key = "invpn_ru_direct"

    static var ruDirect: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Returns the config with RU-direct routing injected, or the original on any parse error.
    static func injectRuDirect(_ configStr: String) -> String {
        guard let data = configStr.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return configStr }

        // Ensure a `direct` outbound exists.
        var outbounds = root["outbounds"] as? [[String: Any]] ?? []
        if !outbounds.contains(where: { ($0["type"] as? String) == "direct" }) {
            outbounds.append(["type": "direct", "tag": "direct"])
        }
        let directTag = (outbounds.first { ($0["type"] as? String) == "direct" }?["tag"] as? String) ?? "direct"
        root["outbounds"] = outbounds

        var route = root["route"] as? [String: Any] ?? [:]

        // Remote RU rule-sets (downloaded directly, not through the tunnel).
        var ruleSet = route["rule_set"] as? [[String: Any]] ?? []
        let have = Set(ruleSet.compactMap { $0["tag"] as? String })
        let defs: [[String: Any]] = [
            ["type": "remote", "tag": "invpn-geoip-ru", "format": "binary",
             "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
             "download_detour": directTag],
            ["type": "remote", "tag": "invpn-geosite-ru", "format": "binary",
             "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs",
             "download_detour": directTag],
        ]
        for d in defs where !have.contains((d["tag"] as? String) ?? "") { ruleSet.append(d) }
        route["rule_set"] = ruleSet

        // Route RU traffic to direct, ahead of the existing rules.
        var rules = route["rules"] as? [[String: Any]] ?? []
        rules.insert(["rule_set": ["invpn-geoip-ru", "invpn-geosite-ru"], "outbound": directTag], at: 0)
        route["rules"] = rules

        root["route"] = route

        guard let out = try? JSONSerialization.data(withJSONObject: root),
              let s = String(data: out, encoding: .utf8) else { return configStr }
        return s
    }
}
