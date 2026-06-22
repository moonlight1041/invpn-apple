import SwiftUI

/// Auth gate — shows the InVPN login/redeem screen until authenticated, then the wrapped app.
/// Mirrors Android's `AuthGate`; observes `AuthRepository.isAuthenticated`.
public struct InVpnRootView<Content: View>: View {
    @StateObject private var auth = AuthRepository.shared
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        if auth.isAuthenticated {
            content()
        } else {
            InVpnAuthView()
        }
    }
}
