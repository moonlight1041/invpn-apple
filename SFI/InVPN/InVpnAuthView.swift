import Library
import SwiftUI

/// InVPN login / invite-redeem screen — mirrors Android `compose/screen/auth/AuthScreen.kt`.
struct InVpnAuthView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var useLogin = false
    @State private var invite = ""
    @State private var username = ""
    @State private var password = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer().frame(height: 48)
                Text("INVPN")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(InVpnTheme.bronze)
                Text("—  ❖  —").foregroundStyle(InVpnTheme.bronze)
                Text(useLogin ? "Вход по логину и паролю" : "Активация по ссылке-приглашению")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer().frame(height: 12)

                if useLogin {
                    TextField("Логин", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    SecureField("Пароль", text: $password)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField("Ссылка или код приглашения", text: $invite)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }

                Button(action: submit) {
                    Group {
                        if loading { ProgressView() } else { Text(useLogin ? "Войти" : "Активировать") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(InVpnTheme.sea)
                .disabled(loading || !canSubmit)

                Button(useLogin ? "У меня есть ссылка-приглашение" : "Войти по логину и паролю") {
                    useLogin.toggle()
                    error = nil
                }
                .font(.callout)
                .tint(InVpnTheme.bronze)
            }
            .padding(28)
        }
    }

    private var canSubmit: Bool {
        useLogin ? (!username.isEmpty && password.count >= 8) : !invite.isEmpty
    }

    private func submit() {
        guard !loading else { return }
        loading = true
        error = nil
        Task { @MainActor in
            do {
                if useLogin {
                    try await AuthRepository.shared.login(
                        username: username.trimmingCharacters(in: .whitespaces), password: password)
                } else {
                    try await AuthRepository.shared.redeemInvite(code: Self.extractInviteCode(invite))
                }
                // Best-effort: fetch + install the per-user config as the managed profile so the
                // dashboard's connect button uses it. Failures are non-fatal (retry from connect).
                try? await ConfigInstaller.refreshAndInstall(environments: environments)
            } catch {
                self.error = (error as? ApiException)?.message ?? error.localizedDescription
            }
            loading = false
        }
    }

    /// Accept a full link (`https://…/i/<code>` or `invpn://i/<code>`) or a bare code.
    static func extractInviteCode(_ input: String) -> String {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = s.range(of: "/i/", options: .backwards) else { return s }
        let after = String(s[r.upperBound...])
        return after.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? after
    }
}
