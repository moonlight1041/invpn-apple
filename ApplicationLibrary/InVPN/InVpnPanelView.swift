import ApplicationLibrary
import Library
import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// INVPN account / servers panel — tier badge, informational server list (Android parity),
/// BRILLIANT invite creation, and logout. Presented as a sheet from the main screen. Additive:
/// does not touch the existing connect/install flow.
public struct InVpnPanelView: View {
    public init() {}

    @Environment(\.dismiss) private var dismiss
    @State private var inviteLink: String?
    @State private var inviteLoading = false
    @State private var inviteError: String?
    @State private var ruDirect = RouteSplit.ruDirect

    private struct ServerInfo: Identifiable {
        let id = UUID()
        let flag: String
        let country: String
        let type: String
        var available = true
        var note: String?
    }

    private let servers: [ServerInfo] = [
        ServerInfo(flag: "🇵🇱", country: "Польша", type: "Статический"),
        ServerInfo(flag: "🇷🇴", country: "Румыния", type: "Статический"),
        ServerInfo(flag: "🇫🇮", country: "Финляндия", type: "Динамический"),
        ServerInfo(flag: "🇺🇸", country: "США · Нью-Джерси", type: "Статический", available: false, note: "Скоро"),
    ]

    public var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AuthRepository.shared.displayName ?? AuthRepository.shared.username ?? "INVPN")
                            .font(.headline)
                        Text(AuthRepository.shared.level)
                            .font(.caption).bold()
                            .foregroundStyle(InVpnTheme.bronze)
                    }
                    .padding(.vertical, 4)
                }

                Section("Серверы") {
                    ForEach(servers) { s in
                        HStack(spacing: 12) {
                            Text(s.flag).font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.country).foregroundStyle(s.available ? .primary : .secondary)
                                if let note = s.note {
                                    Text(note).font(.caption).foregroundStyle(InVpnTheme.bronze)
                                }
                            }
                            Spacer()
                            Text(s.type)
                                .font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .overlay(Capsule().stroke(s.available ? InVpnTheme.sea : .secondary, lineWidth: 1))
                                .foregroundStyle(s.available ? InVpnTheme.sea : .secondary)
                        }
                    }
                }

                Section("Маршрутизация") {
                    Toggle("Российские сервисы напрямую", isOn: $ruDirect)
                        .tint(InVpnTheme.sea)
                        .onChange(of: ruDirect) { newValue in
                            RouteSplit.ruDirect = newValue
                            Task { try? await ConfigInstaller.refreshAndInstall(environments: nil) }
                        }
                    Text("РФ-сайты и сервисы идут напрямую, мимо VPN. Применится при следующем подключении.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if AuthRepository.shared.isBrilliant {
                    Section("Приглашения") {
                        Button(action: createInvite) {
                            if inviteLoading { ProgressView() } else { Text("Создать приглашение") }
                        }
                        if let inviteLink {
                            HStack {
                                Text(inviteLink).font(.caption).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button {
                                    #if os(iOS)
                                        UIPasteboard.general.string = inviteLink
                                    #endif
                                } label: { Image(systemName: "doc.on.doc") }
                            }
                        }
                        if let inviteError {
                            Text(inviteError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        AuthRepository.shared.logout()
                        dismiss()
                    } label: {
                        Text("Выйти из аккаунта")
                    }
                }
            }
            .navigationTitle("INVPN")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        #if !os(macOS)
        .navigationViewStyle(.stack)
        #endif
    }

    private func createInvite() {
        guard !inviteLoading else { return }
        inviteLoading = true
        inviteError = nil
        Task { @MainActor in
            do {
                inviteLink = try await AuthRepository.shared.createInvite(name: nil, level: "GOLDEN")
            } catch {
                inviteError = (error as? ApiException)?.message ?? error.localizedDescription
            }
            inviteLoading = false
        }
    }
}
