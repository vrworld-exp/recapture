#!/usr/bin/env bash
#
# ReCapture API — Deployment Health Check
#
# Verifies a deployed recapture-api instance is live, responding, and
# correctly connected to MongoDB. Handles Render free-tier cold starts
# (service sleeps after 15min inactivity, takes 30-60s to wake).
#
# Usage:
#   ./scripts/health-check.sh <url>
#   ./scripts/health-check.sh https://recapture-api.onrender.com
#
#   If no URL is provided, defaults to http://localhost:3000 (local dev check).
#
# Exit codes:
#   0 — healthy (status: ok, db: connected)
#   1 — unreachable after all retries
#   2 — reachable but unhealthy (db not connected, or unexpected response shape)
#   3 — invalid arguments

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
TARGET_URL="${1:-http://localhost:3000}"
HEALTH_ENDPOINT="${TARGET_URL%/}/health"   # strip trailing slash if present

MAX_RETRIES=8
INITIAL_DELAY=2     # seconds — doubles each retry: 2, 4, 8, 16, 32, 64, 64, 64 (capped)
MAX_DELAY=64
REQUEST_TIMEOUT=10  # seconds per curl attempt

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[health-check] $1"; }
fail() { echo "[health-check] ❌ $1" >&2; exit "$2"; }

# ── Validate arguments ───────────────────────────────────────────────────────
if [[ "$TARGET_URL" != http://* && "$TARGET_URL" != https://* ]]; then
  fail "Invalid URL: '$TARGET_URL' — must start with http:// or https://" 3
fi

log "Target: $HEALTH_ENDPOINT"
log "Max retries: $MAX_RETRIES (exponential backoff, capped at ${MAX_DELAY}s)"

# ── Retry loop with exponential backoff ─────────────────────────────────────
delay=$INITIAL_DELAY
attempt=1
response=""
http_code=""

while (( attempt <= MAX_RETRIES )); do
  log "Attempt $attempt/$MAX_RETRIES..."

  # Capture both body and HTTP status code in one curl call
  if response=$(curl -sS --max-time "$REQUEST_TIMEOUT" \
                     -w '\n%{http_code}' \
                     "$HEALTH_ENDPOINT" 2>/dev/null); then
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
      log "✅ Got HTTP 200 on attempt $attempt"
      break
    else
      log "⚠️  Got HTTP $http_code (attempt $attempt) — retrying..."
    fi
  else
    log "⚠️  Request failed (connection error / timeout) — retrying..."
  fi

  if (( attempt == MAX_RETRIES )); then
    fail "Unreachable after $MAX_RETRIES attempts: $HEALTH_ENDPOINT" 1
  fi

  sleep "$delay"
  delay=$(( delay * 2 ))
  (( delay > MAX_DELAY )) && delay=$MAX_DELAY
  (( attempt++ ))
done

# ── Validate response shape ──────────────────────────────────────────────────
# Expected shape (from src/routes/health.ts):
#   { "status": "ok", "db": "connected", "timestamp": "...", "env": "..." }

if ! command -v jq &> /dev/null; then
  log "⚠️  jq not found — falling back to grep-based validation"
  log "Response body: $body"

  if ! echo "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    fail "Response missing or invalid 'status' field. Body: $body" 2
  fi

  if ! echo "$body" | grep -q '"db"[[:space:]]*:[[:space:]]*"connected"'; then
    fail "Database not connected. Body: $body" 2
  fi

  log "✅ status=ok, db=connected (grep validation)"
else
  status=$(echo "$body" | jq -r '.status // "missing"')
  db=$(echo "$body" | jq -r '.db // "missing"')
  env=$(echo "$body" | jq -r '.env // "missing"')
  timestamp=$(echo "$body" | jq -r '.timestamp // "missing"')

  log "Response: status=$status, db=$db, env=$env, timestamp=$timestamp"

  if [[ "$status" != "ok" ]]; then
    fail "status field is '$status', expected 'ok'. Body: $body" 2
  fi

  if [[ "$db" != "connected" ]]; then
    fail "db field is '$db', expected 'connected'. Body: $body" 2
  fi

  if [[ "$timestamp" == "missing" ]]; then
    fail "Response missing 'timestamp' field. Body: $body" 2
  fi
fi

log "✅ Deployment healthy: $HEALTH_ENDPOINT"
log "   db: connected | env: ${env:-unknown}"
exit 0
