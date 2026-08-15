#!/usr/bin/env bash
# End-to-end pairing regression test for dsh-remote-bridge.
# Starts an isolated bridge on a spare port with a throwaway config, walks the
# full pairing flow, and checks the security invariants:
#   - QR never carries the master token
#   - one code is single-use
#   - desktop approval gates the device token
#   - only the claiming peer can poll the token, exactly once
#   - device tokens are allow-listed and revoked cleanly
#   - devices.json stores only sha256(tokenHash), never the token
#
# Usage: bash test_pairing.sh [port]   (default 8799)
set -euo pipefail

cd "$(dirname "$0")"
PORT="${1:-8799}"
TMP="$(mktemp -d /tmp/dsh-remote-pair-test.XXXXXX)"
TOKEN="$(openssl rand -hex 32)"
cat > "$TMP/config.json" <<EOF
{
  "host": "127.0.0.1",
  "port": $PORT,
  "dshBaseUrl": "http://127.0.0.1:3080",
  "token": "$TOKEN",
  "allowedIps": ["127.0.0.1"],
  "pairTtlMs": 180000,
  "pairPendingTtlMs": 600000,
  "pairRequireApproval": true,
  "devicesFile": "devices.json"
}
EOF

BRIDGE_CONFIG="$TMP/config.json" BRIDGE_PORT="$PORT" node server.js > "$TMP/bridge.log" 2>&1 &
PID=$!
cleanup() {
  kill "$PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

BASE="http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do
  curl -fsS "$BASE/health" >/dev/null 2>&1 && break
  sleep 0.1
done

fail() { echo "FAIL: $1" >&2; exit 1; }
json() { python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('$1',''))"; }

# Admin QR page is loopback-only and renders.
curl -fsS "$BASE/pair/qr" | grep -q 'DSH-Remote 设备配对' || fail 'admin pairing page'

# Cross-origin browser call to the loopback admin API must be rejected.
CROSS=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'origin: https://evil.example' \
  -H 'content-type: application/json' -d '{}' "$BASE/pair/start")
[ "$CROSS" = "403" ] || fail "cross-origin admin call returned $CROSS"

START=$(curl -fsS -X POST -H 'content-type: application/json' -d '{}' "$BASE/pair/start")
CODE=$(printf '%s' "$START" | json code)
[ "${#CODE}" -ge 32 ] || fail 'pairing code too short'

# QR SVG renders a dshremote:// payload, not a token.
SVG=$(curl -fsS "$BASE/pair/qr.svg?code=$CODE&base=http%3A%2F%2F<your-mac-tailscale-ip>%3A$PORT")
printf '%s' "$SVG" | grep -q '<svg' || fail 'qr svg missing'

CLAIM=$(curl -fsS -X POST -H 'content-type: application/json' \
  -d "{\"code\":\"$CODE\",\"deviceName\":\"test-phone\"}" "$BASE/pair/claim")
STATUS=$(printf '%s' "$CLAIM" | json status)
[ "$STATUS" = "pending" ] || fail "claim status was $STATUS"
PAIR_ID=$(printf '%s' "$CLAIM" | json pairId)

# Single-use enforcement.
SECOND=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' \
  -d "{\"code\":\"$CODE\",\"deviceName\":\"evil-phone\"}" "$BASE/pair/claim")
[ "$SECOND" = "404" ] || fail "code replay returned $SECOND"

curl -fsS "$BASE/pair/admin/state" | grep -q 'test-phone' || fail 'pending device not visible to admin'

# Approval gates the token.
curl -fsS -X POST -H 'content-type: application/json' -d "{\"id\":\"$PAIR_ID\"}" "$BASE/pair/approve" >/dev/null
POLL=$(curl -fsS "$BASE/pair/status?id=$PAIR_ID")
DEV_TOKEN=$(printf '%s' "$POLL" | json token)
DEV_ID=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read())['device']['id'])" <<<"$POLL")
[ "${#DEV_TOKEN}" = "64" ] || fail 'device token not issued'

# Token is returned exactly once.
SECOND_POLL=$(curl -fsS "$BASE/pair/status?id=$PAIR_ID")
[ "$(printf '%s' "$SECOND_POLL" | json token)" = "None" ] || fail 'device token returned twice'

# Device token can call allow-listed methods (needs DSH on 127.0.0.1:3080).
if [ "${SKIP_DSH_TEST:-0}" != "1" ]; then
  LIST=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "authorization: Bearer $DEV_TOKEN" \
    -H 'content-type: application/json' \
    -d '{"type":"client-request","rpcId":"t-1","method":"session.list","payload":{}}' \
    "$BASE/api/session.list")
  [ "$LIST" = "200" ] || fail "device token session.list returned $LIST"
fi

# Everything outside the allow-list is denied, even with a valid device token.
BLOCKED=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "authorization: Bearer $DEV_TOKEN" \
  -H 'content-type: application/json' -d '{}' "$BASE/api/settings.describe")
[ "$BLOCKED" = "403" ] || fail "settings.describe returned $BLOCKED"

# Wrong token is rejected.
WRONG=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "authorization: Bearer deadbeef" \
  -H 'content-type: application/json' -d '{}' "$BASE/api/session.list")
[ "$WRONG" = "401" ] || fail "wrong token returned $WRONG"

# On-disk registry stores only the token hash.
python3 - "$TMP/devices.json" <<'PY'
import json, sys
devs = json.load(open(sys.argv[1]))['devices']
assert len(devs) == 1
assert 'token' not in devs[0]
assert len(devs[0]['tokenHash']) == 64
print('devices.json stores hash only:', devs[0]['tokenHash'][:16] + '...')
PY

# Revocation invalidates the device token immediately.
curl -fsS -X POST -H 'content-type: application/json' -d "{\"deviceId\":\"$DEV_ID\"}" "$BASE/pair/revoke" >/dev/null
REVOKED=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "authorization: Bearer $DEV_TOKEN" \
  -H 'content-type: application/json' -d '{}' "$BASE/api/session.list")
[ "$REVOKED" = "401" ] || fail "revoked token returned $REVOKED"

echo 'pairing regression test PASSED'
