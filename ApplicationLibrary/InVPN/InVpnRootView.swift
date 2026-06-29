import Library
import SwiftUI

/// Auth gate — shows the InVPN login/redeem screen until authenticated, then the wrapped app.
/// Consent gate — after auth, shows ConsentView until telemetry consent is granted.
/// Mirrors Android's `AuthGate`; observes `AuthRepository.isAuthenticated`.
public struct InVpnRootView<Content: View>: View {
    @StateObject private var auth = AuthRepository.shared
    /// Mirrors `SharedPreferences.telemetryConsentGiven`; loaded once in `.task` on first appear.
    /// Updated synchronously when the user accepts in ConsentView.
    @State private var telemetryConsentGiven = false
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        Group {
            if !auth.isAuthenticated {
                InVpnAuthView()
            } else if !telemetryConsentGiven {
                ConsentView(onAccept: {
                    telemetryConsentGiven = true
                })
            } else {
                content()
            }
        }
        .task {
            // Load the persisted consent flag once at startup.
            // If already granted (returning user), wire telemetry hooks immediately.
            let given = await SharedPreferences.telemetryConsentGiven.get()
            telemetryConsentGiven = given
            if given {
                Telemetry.installHooks()
            }
        }
    }
}
