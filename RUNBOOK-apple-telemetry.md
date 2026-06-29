# INVPN macOS/iOS Telemetry — e2e test runbook

The backend `/t/` is LIVE on `ofjnb.net` and proven end-to-end. This tests the full
pipeline on **macOS** (free, real tunnel — no $99 needed). iPhone needs $99 + TestFlight.

## 1. Get the telemetry branch (on the Mac)
```
cd invpn-apple            # or: git clone https://github.com/moonlight1041/invpn-apple
git fetch && git checkout feat/telemetry
./mac-build.sh            # builds Libbox.xcframework (gomobile) + opens Xcode
```

## 2. Run SFM (macOS) in Xcode
- Scheme = **SFM**. Signing = your free Apple ID team (`-skipPackagePluginValidation` already handled).
- Run. macOS will prompt to approve the **system extension** → System Settings → Privacy & Security → Allow.

## 3. Exercise telemetry
- Log in (founder `founder` / `KrBBAXGxbWEy_EOE`, or redeem an invite).
- A NEW **consent screen** appears («Принимаю») — accept it (telemetry is gated on consent + login).
- **Connect** the VPN → fires `connect_success` + starts the heartbeat (reachability check every 45s).
- Let it run ~1–2 min.
- **Disconnect** / toggle Wi-Fi → fires `disconnect` / `connect_fail`. If the tunnel connects but data
  stalls (the Wi-Fi/PMTU case), the heartbeat fires a `degradation` event with the network context.

## 4. Verification (I do this)
Tell me you've run it (and roughly when). I query the NL#2 Postgres for events from your account
and confirm the pipeline: `connect_*` / `disconnect` / `heartbeat` / `degradation` rows with
`net_type`, `ssid` (macOS via CoreWLAN), `expensive/constrained`, `egress_ip`, etc.

## Notes
- `API_BASE = https://ofjnb.net` (live). Telemetry POSTs encrypted batches to `/t/v1/events`.
- v1 captures main-app connection events + network context + the heartbeat data-stall signal.
  Not captured yet: NE-internal handshake fail_phase (the NE process can't reach the facade — a
  follow-up would buffer in the NE). Wi-Fi SSID on **iPhone** needs the "Access WiFi Information"
  entitlement (added at the TestFlight signing step); on **Mac** it comes from CoreWLAN.
- No GPS, ever. Consent required. Data encrypted (HKDF-from-deviceToken → AES-256-GCM).
