import ApplicationLibrary
import Foundation
import Library
import SwiftUI

@main
struct Application: App {
    @UIApplicationDelegateAdaptor private var appDelegate: ApplicationDelegate
    @StateObject private var environments = ExtensionEnvironments()
    @StateObject private var peerStore = TailscaleSSHPeerStore()

    init() {
        Task { @MainActor in
            ImportedFontStore.shared.bootstrap()
        }
    }

    var body: some Scene {
        WindowGroup {
            // Environment objects live above the auth gate so the InVPN auth screen (and
            // ConfigInstaller it triggers) can use ExtensionEnvironments too; MainView inherits them.
            InVpnRootView {
                MainView()
            }
            .environmentObject(environments)
            .environmentObject(peerStore)
        }
    }
}
