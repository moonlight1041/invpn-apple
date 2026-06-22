#!/usr/bin/env bash
# INVPN — build & run on YOUR Mac for a free, real-tunnel test (no $99).
# Requires: Xcode (App Store) + Go (`brew install go`). Run:  bash mac-build.sh
set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")" && pwd)}"
SINGBOX_COMMIT="236430100c3300d7c75e99a277d4984889639d3f"   # sing-box `testing` HEAD this app targets

cd "$REPO_DIR"
echo "==> repo: $REPO_DIR"
echo "==> fetching submodules (Runestone)…"
git submodule update --init --recursive

# Build Libbox.xcframework (the sing-box engine) via gomobile — the one heavy step.
if [ -d Libbox.xcframework ]; then
  echo "==> Libbox.xcframework already present, skipping build."
else
  command -v go >/dev/null || { echo "Go not found. Install with:  brew install go"; exit 1; }
  echo "==> building Libbox.xcframework from sing-box $SINGBOX_COMMIT (a few minutes)…"
  rm -rf /tmp/sb-invpn && mkdir -p /tmp/sb-invpn && cd /tmp/sb-invpn
  git init -q && git remote add origin https://github.com/SagerNet/sing-box.git
  git fetch -q --depth 1 origin "$SINGBOX_COMMIT" && git checkout -q FETCH_HEAD
  make lib_install
  export PATH="$PATH:$(go env GOPATH)/bin"
  make lib_apple
  XCF="$(find . -name 'Libbox.xcframework' -type d -print -quit)"
  test -n "$XCF"
  cp -R "$XCF" "$REPO_DIR/Libbox.xcframework"
  cd "$REPO_DIR"
fi

echo "==> opening Xcode…"
open sing-box.xcodeproj
cat <<'NEXT'

============================  NEXT STEPS IN XCODE  ============================
1. Scheme: pick  SFM  (top bar) and destination  My Mac.
2. Signing: for the SFM target AND the Extension target → Signing & Capabilities →
   Team = your free Apple ID (add it in Xcode ▸ Settings ▸ Accounts). Let Xcode
   auto-manage signing (it'll pick a com.* bundle id — that's fine for local run).
3. Run (⌘R). On first connect macOS asks to allow the system/VPN extension →
   System Settings ▸ Privacy & Security ▸ Allow.
4. In INVPN: log in  founder / KrBBAXGxbWEy_EOE   (or redeem invite INVPN-MVP4),
   then press Connect. That's the real tunnel — free, on your Mac.
=============================================================================
NEXT
