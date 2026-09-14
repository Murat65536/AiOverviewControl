#!/usr/bin/env bash
# xAI / Grok usage — fake-curl unit test.
# Verifies grok login CLI-proxy billing, omitted-percent = 0%, Management API
# prepaid cents, XAI_API_KEY auth-only fallback, and health/credential errors.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HDR_LOG="$TMP/headers.log"
export XDG_CACHE_HOME="$TMP/cache"
mkdir -p "$TMP/bin"

# Fake curl that mimics real curl behavior:
#   -o file   → writes body to file, suppresses body on stdout
#   -w FORMAT → writes FORMAT to stdout (independent of -o)
# The stub MUST exit 0 in every branch — the parent script runs a settings
# curl without -w and treats a non-zero exit as a network error.
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
url=""
write_code=0
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -o) out="${args[$((i + 1))]}" ;;
    -w) write_code=1 ;;
    -H) printf '%s\n' "${args[$((i + 1))]}" >> "${HDR_LOG:-/dev/null}" ;;
    http*) url="${args[$i]}" ;;
  esac
done
status=200
case "$url" in
  *format=credits*)
    case "${XAI_BILLING_MODE:-ok}" in
      ok)     [ -n "$out" ] && cp "${XAI_FIXTURE_DIR}/xai-cli-billing-credits.json" "$out"; status=200 ;;
      zero)   [ -n "$out" ] && cp "${XAI_FIXTURE_DIR}/xai-cli-billing-credits-zero.json" "$out"; status=200 ;;
      down)   [ -n "$out" ] && printf '' > "$out"; status=500 ;;
      deny)   [ -n "$out" ] && printf '{"error":"Access denied"}' > "$out"; status=403 ;;
    esac
    ;;
  */settings)
    [ -n "$out" ] && cp "${XAI_FIXTURE_DIR}/xai-cli-settings.json" "$out"
    status=200
    ;;
  *prepaid/balance*)
    case "${XAI_MGMT_MODE:-ok}" in
      ok)     [ -n "$out" ] && cp "${XAI_FIXTURE_DIR}/xai-management-balance.json" "$out"; status=200 ;;
      deny)   [ -n "$out" ] && printf '{"error":"unauthorized"}' > "$out"; status=401 ;;
    esac
    ;;
  */v1/api-key)
    [ -n "$out" ] && cp "${XAI_FIXTURE_DIR}/xai-api-key.json" "$out"
    status=200
    ;;
  *)
    [ -n "$out" ] && printf '' > "$out"
    status=404
    ;;
esac
if [ "$write_code" -eq 1 ]; then printf '%s' "$status"; fi
exit 0
STUB
chmod +x "$TMP/bin/curl"

write_auth() {
  local dest="$1" token="$2" expiry="$3"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<EOF
{
  "https://auth.x.ai::test-client": {
    "key": "${token}",
    "auth_mode": "oidc",
    "email": "test@example.com",
    "team_id": "team-test",
    "principal_type": "User",
    "expires_at": "${expiry}"
  }
}
EOF
  chmod 600 "$dest"
}

run() {
  PATH="$TMP/bin:$PATH" HDR_LOG="$HDR_LOG" XAI_FIXTURE_DIR="$ROOT/tests/fixtures" \
    "$@" "$ROOT/providers/get-provider-usage" xai 2>/dev/null
}
fail() { echo "FAIL: $1" >&2; exit 1; }

CLI_HOME="$TMP/cli-home"
write_auth "$CLI_HOME/.grok/auth.json" "cli_test_token" "2099-01-01T00:00:00Z"

# 1. grok login + credits payload with creditUsagePercent.
: > "$HDR_LOG"
out="$(run env -u XAI_API_KEY -u XAI_MANAGEMENT_KEY -u XAI_MANAGEMENT_API_KEY \
  HOME="$CLI_HOME" GROK_HOME="$CLI_HOME/.grok" XAI_BILLING_MODE=ok)"
[ "$(jq -r '.[0].source' <<<"$out")" = "grok-cli-billing" ] || fail "cli source: $out"
[ "$(jq -r '.[0].usage.primary.usedPercent|floor' <<<"$out")" = "32" ] || fail "cli percent"
[ "$(jq -r '.[0].usage.primary.windowMinutes' <<<"$out")" = "10080" ] || fail "cli weekly minutes"
[ "$(jq -r '.[0].usage.primary.resetDescription' <<<"$out")" = "Weekly" ] || fail "cli weekly label"
[ "$(jq -r '.[0].usage.identity.accountEmail' <<<"$out")" = "test@example.com" ] || fail "cli email"
[ "$(jq -r '.[0].usage.identity.loginMethod' <<<"$out")" = "SuperGrok" ] || fail "cli plan from settings"
[ "$(jq -r '.[0].credits.remaining' <<<"$out")" = "SuperGrok" ] || fail "cli credits plan"
grep -q '^Authorization: Bearer cli_test_token$' "$HDR_LOG" || fail "cli auth header"
grep -q '^x-xai-token-auth: xai-grok-cli$' "$HDR_LOG" || fail "cli token-auth header"
health="$(env -u XAI_API_KEY -u XAI_MANAGEMENT_KEY -u XAI_MANAGEMENT_API_KEY \
  HOME="$CLI_HOME" GROK_HOME="$CLI_HOME/.grok" \
  "$ROOT/providers/get-provider-health" xai 2>/dev/null)"
[ "$(jq -r '.[0].status' <<<"$health")" = "ready" ] || fail "cli health ready"

# 2. Omitted creditUsagePercent on a valid period is 0%, not an error.
: > "$HDR_LOG"
out="$(run env -u XAI_API_KEY -u XAI_MANAGEMENT_KEY -u XAI_MANAGEMENT_API_KEY \
  HOME="$CLI_HOME" GROK_HOME="$CLI_HOME/.grok" XAI_BILLING_MODE=zero)"
[ "$(jq -r '.[0].source' <<<"$out")" = "grok-cli-billing" ] || fail "zero source"
[ "$(jq -r '.[0].usage.primary.usedPercent' <<<"$out")" = "0" ] || fail "zero percent"
[ "$(jq -r '.[0].usage.primary.windowMinutes' <<<"$out")" = "10080" ] || fail "zero still weekly"

# 3. grok login billing 403 falls through to Management API prepaid balance.
: > "$HDR_LOG"
out="$(run env -u XAI_API_KEY \
  HOME="$CLI_HOME" GROK_HOME="$CLI_HOME/.grok" \
  XAI_BILLING_MODE=deny XAI_MGMT_MODE=ok \
  XAI_MANAGEMENT_KEY=mgmt_test XAI_TEAM_ID=team-test)"
[ "$(jq -r '.[0].source' <<<"$out")" = "xai-management" ] || fail "mgmt source: $out"
[ "$(jq -r '.[0].credits.remaining' <<<"$out")" = '$12.50' ] || fail "mgmt remaining"
grep -q '^Authorization: Bearer mgmt_test$' "$HDR_LOG" || fail "mgmt auth header"

# 4. Management key without grok login.
EMPTY_HOME="$TMP/empty-home"
mkdir -p "$EMPTY_HOME"
: > "$HDR_LOG"
out="$(run env -u XAI_API_KEY \
  HOME="$EMPTY_HOME" GROK_HOME="$EMPTY_HOME/.grok" \
  XAI_MGMT_MODE=ok XAI_MANAGEMENT_KEY=mgmt_test XAI_TEAM_ID=team-test)"
[ "$(jq -r '.[0].source' <<<"$out")" = "xai-management" ] || fail "mgmt-only source"
[ "$(jq -r '.[0].credits.remaining' <<<"$out")" = '$12.50' ] || fail "mgmt-only remaining"

# 5. Inference API key is auth-only (no quota).
: > "$HDR_LOG"
out="$(run env -u XAI_MANAGEMENT_KEY -u XAI_MANAGEMENT_API_KEY \
  HOME="$EMPTY_HOME" GROK_HOME="$EMPTY_HOME/.grok" XAI_API_KEY=user_test)"
[ "$(jq -r '.[0].source' <<<"$out")" = "xai-api" ] || fail "api-key source"
[ "$(jq -r '.[0].usage.identity.accountEmail' <<<"$out")" = "desktop" ] || fail "api-key name"
grep -q '^Authorization: Bearer user_test$' "$HDR_LOG" || fail "api-key auth header"

# 6. Expired grok login with no other creds.
EXPIRED_HOME="$TMP/expired-home"
write_auth "$EXPIRED_HOME/.grok/auth.json" "expired_token" "2020-01-01T00:00:00Z"
out="$(run env -u XAI_API_KEY -u XAI_MANAGEMENT_KEY -u XAI_MANAGEMENT_API_KEY \
  HOME="$EXPIRED_HOME" GROK_HOME="$EXPIRED_HOME/.grok")"
[ "$(jq -r '.[0].error.kind' <<<"$out")" = "provider" ] || fail "expired kind"
echo "$(jq -r '.[0].error.message' <<<"$out")" | grep -q 'expired' || fail "expired message"

# 7. No credential source.
out="$(run env -u XAI_API_KEY -u XAI_MANAGEMENT_KEY -u XAI_MANAGEMENT_API_KEY \
  HOME="$EMPTY_HOME" GROK_HOME="$EMPTY_HOME/.grok")"
[ "$(jq -r '.[0].error.kind' <<<"$out")" = "provider" ] || fail "no-key kind"
echo "$(jq -r '.[0].error.message' <<<"$out")" | grep -q 'grok login' || fail "no-key mentions grok login"
health="$(env -u XAI_API_KEY -u XAI_MANAGEMENT_KEY -u XAI_MANAGEMENT_API_KEY \
  HOME="$EMPTY_HOME" GROK_HOME="$EMPTY_HOME/.grok" \
  "$ROOT/providers/get-provider-health" xai 2>/dev/null)"
[ "$(jq -r '.[0].status' <<<"$health")" = "missing" ] || fail "empty health missing"

# 8. grok alias dispatches the same adapter.
out="$(PATH="$TMP/bin:$PATH" HDR_LOG="$HDR_LOG" XAI_FIXTURE_DIR="$ROOT/tests/fixtures" \
  env -u XAI_API_KEY -u XAI_MANAGEMENT_KEY -u XAI_MANAGEMENT_API_KEY \
  HOME="$CLI_HOME" GROK_HOME="$CLI_HOME/.grok" XAI_BILLING_MODE=ok \
  "$ROOT/providers/get-provider-usage" grok 2>/dev/null)"
[ "$(jq -r '.[0].provider' <<<"$out")" = "xai" ] || fail "grok alias provider"
[ "$(jq -r '.[0].source' <<<"$out")" = "grok-cli-billing" ] || fail "grok alias source"

echo "OK: test-xai"
