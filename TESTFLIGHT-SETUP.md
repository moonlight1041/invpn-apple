# INVPN iOS — TestFlight setup

The project is rebranded to **com.invpn.app** and prepped for signing. Do these on your
Mac with your Apple Developer account ($99). I handle any code fixes you hit.

## 0. Prereqs
- Apple Developer Program active ($99, Individual).
- On your Mac: `git checkout feat/telemetry` → `./mac-build.sh` (builds Libbox, opens Xcode).

## 1. Set your Team (signing is already "Automatic")
Xcode → project → for each target → **Signing & Capabilities → Team = your team**:
- **SFI** (the iOS app) — main
- **Extension** (the packet tunnel) — critical, must match
- IntentsExtension, FileProviderExtension, WidgetExtension (embedded in SFI)

Xcode automatic signing then creates the App IDs + provisioning profiles for you.

## 2. Capabilities (entitlements already set; Xcode auto-registers)
- **App Groups**: `group.com.invpn.app` — the app + tunnel share this. **Do NOT change it** or the tunnel breaks.
- **Network Extensions**: packet-tunnel-provider
- **Access WiFi Information** (for the Wi-Fi SSID telemetry)
- **iCloud** (CloudDocuments) — *optional*; if it adds friction, just remove the iCloud capability in Xcode (INVPN doesn't need it — tell me and I'll strip it from the entitlements).
- **Personal VPN** — add if Xcode asks.

## 3. FIRST: verify the tunnel still works (we rebranded the app group)
Run **SFM** (macOS) or **SFI** on a device → connect the VPN. If it connects + passes traffic,
the app-group rebrand is good. If the shared DB / tunnel fails → tell me, I fix.
(Full steps: `RUNBOOK-apple-telemetry.md`.)

## 4. App Store Connect — create the app
appstoreconnect.apple.com → Apps → ＋ → New App: iOS, Name **INVPN**, Bundle ID **com.invpn.app**.

## 5. Archive + upload
- Xcode: scheme **SFI**, destination **Any iOS Device (arm64)**.
- Product → **Archive** → Organizer → **Distribute App → App Store Connect → Upload**.
- Export compliance: `ITSAppUsesNonExemptEncryption=false` is already set (standard TLS). Confirm if prompted.

## 6. TestFlight → install on iPhone
App Store Connect → your app → **TestFlight**:
- **Internal** (you + up to 100, INSTANT, no review) — add testers by Apple ID. Best for diagnosing the Wi-Fi issue fast.
- **External** (up to 10 000 by link, ~1-day beta review).

Share the **invite link** → tester installs the **TestFlight** app → taps **Install**. One tap, done.

## Notes
- Bundle IDs: com.invpn.app + .extension / .intents / .fileprovider / .widget (Xcode registers them on archive).
- If Xcode says a capability can't be registered, send me the exact message.
- Backend/login/invites unchanged. Telemetry flows to `ofjnb.net/t/` (already live).
