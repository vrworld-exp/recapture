#!/usr/bin/env bash
# Rebuild ReCapture (release) and install + launch it on a connected iPhone.
#
# Usage:
#   scripts/run_ios_device.sh                # rebuild + install + launch
#   scripts/run_ios_device.sh --clean        # flutter clean + wipe DerivedData/Pods first
#   scripts/run_ios_device.sh --no-backend   # don't start/check the local backend
#
# Requires: flutter, Xcode command line tools, python3, a paired iPhone with
# Developer Mode on. The device must be UNLOCKED for install/launch, and the
# developer certificate must be trusted on it (Settings > General > VPN &
# Device Management) — a fresh signature after --clean often needs re-trusting.
#
# A free (non-paid) Apple account's provisioning profile is valid 7 days —
# after that this script's build will fail to launch until re-signed, which
# just means running this script again.

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.mayasabhaxr.recapture"
BACKEND_PORT=3000
CLEAN=0
START_BACKEND=1

for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --no-backend) START_BACKEND=0 ;;
    -h|--help)
      sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (use --clean / --no-backend)" >&2; exit 1 ;;
  esac
done

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. Local backend — started only for the LAN dev flow. If .env overrides
#    API_BASE_URL to a remote host (Render etc.), the app won't call this at
#    all; it's still safe/useful to leave running for other tooling.
# ---------------------------------------------------------------------------
if [ "$START_BACKEND" = "1" ]; then
  log "Checking local backend on :$BACKEND_PORT"
  if curl -s -o /dev/null --max-time 2 "http://localhost:$BACKEND_PORT/health"; then
    echo "Already running and healthy — leaving it alone."
  else
    echo "Not running — starting it."
    ( cd recapture-api && npm install --no-audit --no-fund > /tmp/recapture_backend_install.log 2>&1 )
    BACKEND_LOG="/tmp/recapture_backend.log"
    ( cd recapture-api && nohup npm run dev > "$BACKEND_LOG" 2>&1 & disown )
    for _ in $(seq 1 30); do
      if curl -s -o /dev/null --max-time 2 "http://localhost:$BACKEND_PORT/health"; then
        echo "Backend is up (log: $BACKEND_LOG)."
        break
      fi
      sleep 1
    done
    if ! curl -s -o /dev/null --max-time 2 "http://localhost:$BACKEND_PORT/health"; then
      warn "Backend did not come up in time — check $BACKEND_LOG"
    fi
  fi
  LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "?")
  CONFIGURED_IP=$(grep -m1 '^API_BASE_URL=' .env.dev 2>/dev/null | sed -E 's#.*//([0-9.]+):.*#\1#')
  if [ -n "$CONFIGURED_IP" ] && [ "$LAN_IP" != "$CONFIGURED_IP" ]; then
    warn "This Mac's LAN IP ($LAN_IP) != .env.dev's API_BASE_URL host ($CONFIGURED_IP)."
    warn "If .env doesn't override API_BASE_URL to a remote host, update .env.dev."
  fi
fi

# ---------------------------------------------------------------------------
# 2. Pick the connected iPhone (first paired+available physical iOS device).
# ---------------------------------------------------------------------------
log "Looking for a connected iPhone"
DEVICE_JSON="/tmp/recapture_devices.json"
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1

read -r DEVICE_UDID DEVICE_NAME <<EOF
$(python3 -c "
import json
d = json.load(open('$DEVICE_JSON'))
for dev in d['result']['devices']:
    props = dev.get('deviceProperties', {})
    conn = dev.get('connectionProperties', {})
    plat = dev.get('hardwareProperties', {}).get('platform', '')
    if plat == 'iOS' and conn.get('pairingState') == 'paired' and conn.get('tunnelState') != 'unavailable':
        print(dev['hardwareProperties']['udid'], props.get('name', 'iPhone'))
        break
")
EOF

if [ -z "${DEVICE_UDID:-}" ]; then
  echo "No available iPhone found. Plug it in and unlock it." >&2
  exit 1
fi
echo "Using: $DEVICE_NAME ($DEVICE_UDID)"

# ---------------------------------------------------------------------------
# 3. Build
# ---------------------------------------------------------------------------
if [ "$CLEAN" = "1" ]; then
  log "Full clean (flutter clean + DerivedData + Pods)"
  flutter clean
  rm -rf ~/Library/Developer/Xcode/DerivedData/Runner-*
  rm -rf ios/Pods ios/Podfile.lock
fi

log "flutter pub get"
flutter pub get

log "Building iOS release"
flutter build ios --release

APP_PATH="build/ios/iphoneos/Runner.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Build did not produce $APP_PATH — aborting." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Install
# ---------------------------------------------------------------------------
log "Installing on $DEVICE_NAME"
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"

# ---------------------------------------------------------------------------
# 5. Launch — retries because a fresh signature routinely needs the developer
#    profile re-trusted on-device, and a locked screen blocks launch outright.
#    Both are just prompts for the user to clear; this loop waits them out.
# ---------------------------------------------------------------------------
log "Launching $BUNDLE_ID"
TOLD_TRUST=0
TOLD_UNLOCK=0
for _ in $(seq 1 60); do
  OUT=$(xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing "$BUNDLE_ID" 2>&1) || true
  if echo "$OUT" | grep -q "Launched application"; then
    echo "Launched."
    exit 0
  fi
  if echo "$OUT" | grep -qi "not been explicitly trusted\|invalid code signature"; then
    if [ "$TOLD_TRUST" = "0" ]; then
      warn "On the iPhone: Settings > General > VPN & Device Management > trust the developer profile."
      TOLD_TRUST=1
    fi
  elif echo "$OUT" | grep -qi "Locked"; then
    if [ "$TOLD_UNLOCK" = "0" ]; then
      warn "Unlock the iPhone to continue."
      TOLD_UNLOCK=1
    fi
  fi
  sleep 3
done

echo "Gave up waiting to launch. Last output:" >&2
echo "$OUT" >&2
exit 1
