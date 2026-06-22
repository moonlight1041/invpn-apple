import SwiftUI

/// Auth gate — shows the InVPN login/redeem screen until authenticated, then the wrapped app.
/// Mirrors Android's `AuthGate`; observes `AuthRepository.isAuthenticated`.
struct InVpnRootView<Content: View>: View {
    @StateObject private var auth = AuthRepository.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        if auth.isAuthenticated {
            content()
        } else {
            InVpnAuthView()
        }
    }
}
