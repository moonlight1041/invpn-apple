import Foundation
import Libbox
import Library

/// Fetch the per-user config, decrypt it, and install/refresh the single managed "InVPN" local
/// profile (then select it). Mirrors Android `invpn/ConfigInstaller`. The existing dashboard/connect
/// flow drives the tunnel from the selected profile; we just keep that profile's config current.
enum ConfigInstaller {
    @discardableResult
    static func refreshAndInstall(environments: ExtensionEnvironments? = nil) async throws -> Int64 {
        guard let creds = SecureStore.load() else {
            throw ApiException(code: -1, message: "not authenticated")
        }
        let blob = try await ApiClient.shared.fetchConfig(deviceToken: creds.deviceToken)
        let bodyKey = try Crypto.b64UrlDecode(creds.bodyKeyB64)
        let data = try Crypto.decryptWithBodyKey(bodyKey, nonceB64: blob.nonce, ctB64: blob.ct)
        guard let original = String(data: data, encoding: .utf8) else {
            throw ApiException(code: -1, message: "config decode failed")
        }

        // Optionally inject «РФ напрямую» routing, then validate with the engine that will run it.
        // If the injected config is rejected, fall back to the original so the tunnel never breaks.
        var configStr = RouteSplit.ruDirect ? RouteSplit.injectRuDirect(original) : original
        var checkError: NSError?
        LibboxCheckConfig(configStr, &checkError)
        if checkError != nil {
            configStr = original
            var fallbackError: NSError?
            LibboxCheckConfig(configStr, &fallbackError)
            if let fallbackError { throw fallbackError }
        }

        let name = InVpnConfig.managedProfileName
        let profileID: Int64
        if let existing = try await ProfileManager.get(by: name) {
            profileID = existing.mustID
            try write(configStr, relativePath: existing.path)
            existing.lastUpdated = Date()
            try await ProfileManager.update(existing)
        } else {
            let id = try await ProfileManager.nextID()
            let relPath = "configs/config_\(id).json"
            try write(configStr, relativePath: relPath)
            let profile = Profile(name: name, type: .local, path: relPath, lastUpdated: Date())
            try await ProfileManager.create(profile)
            profileID = profile.mustID
        }

        await SharedPreferences.selectedProfileID.set(profileID)
        if let environments {
            await MainActor.run {
                environments.selectedProfileUpdate.send()
                environments.profileUpdate.send()
            }
        }
        return profileID
    }

    private static func write(_ config: String, relativePath: String) throws {
        let dir = FilePath.sharedDirectory.appendingPathComponent("configs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = FilePath.sharedDirectory.appendingPathComponent(relativePath)
        try config.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
