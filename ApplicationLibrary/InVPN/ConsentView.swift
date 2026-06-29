import Library
import SwiftUI

/// Telemetry consent screen — shown once after first login, before the main app content.
/// Explains what is collected, why, and where; matches the InVPN Aegean/Bronze visual language.
struct ConsentView: View {
    let onAccept: () -> Void
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer().frame(height: 48)
                Text("INVPN")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(InVpnTheme.bronze)
                Text("—  ❖  —").foregroundStyle(InVpnTheme.bronze)
                Text("Диагностика")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer().frame(height: 12)

                VStack(alignment: .leading, spacing: 12) {
                    DiagRow(
                        label: "Что",
                        text: "События подключения (успех / ошибка / разрыв), тип сети и имя Wi-Fi (SSID), MTU, коды ошибок."
                    )
                    DiagRow(
                        label: "Зачем",
                        text: "Находить причины проблем — например, «не работает на Wi-Fi» — без расспросов."
                    )
                    DiagRow(
                        label: "Куда",
                        text: "Зашифровано на наш сервер. GPS не используется."
                    )
                }
                .padding(16)
                .background(InVpnTheme.ink.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Spacer().frame(height: 8)

                Button(action: accept) {
                    Group {
                        if loading { ProgressView() } else { Text("Принимаю") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(InVpnTheme.sea)
                .disabled(loading)

                Link("Подробнее", destination: URL(string: "https://ofjnb.net/privacy")!)
                    .font(.callout)
                    .tint(InVpnTheme.bronze)
            }
            .padding(28)
        }
    }

    private func accept() {
        guard !loading else { return }
        loading = true
        Task { @MainActor in
            await SharedPreferences.telemetryConsentGiven.set(true)
            Telemetry.installHooks()
            onAccept()
        }
    }
}

// MARK: - Private helper

private struct DiagRow: View {
    let label: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.callout).bold()
                .foregroundStyle(InVpnTheme.bronze)
                .frame(width: 52, alignment: .leading)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
    }
}
