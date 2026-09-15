#!/usr/bin/env bash
# MiniMax Token Plan quota tracking — fake-curl unit test.
#
# Verifies:
#   - MINIMAX_TOKEN_PLAN_KEY priority over MINIMAX_API_KEY.
#   - sk-cp MINIMAX_API_KEY → token plan path (back-compat).
#   - sk-api MINIMAX_API_KEY → /v1/models auth-only path.
#   - 5h primary, weekly secondary, both ms→ISO reset conversion.
#   - status 2 (exhausted) → 100% used, status 3 with totals==0 → no fake unlimited.
#   - malformed/empty model_remains array → json_error, not a 0% usage.
#   - get-provider-health recognises MINIMAX_TOKEN_PLAN_KEY.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HDR_LOG="$TMP/headers.log"
# Sandbox the dispatcher history so fixture runs never touch the developer's
# real chart cache, regardless of calling environment.
export XDG_CACHE_HOME="$TMP/cache"
mkdir -p "$TMP/bin"

# Fake curl that mimics real curl behaviour: -o writes the body to a file,
# -w writes the HTTP status code to stdout, and -H echoes each header into
# HDR_LOG so the test can prove the Bearer token was forwarded. Always exits
# 0 to keep curl-as-error-handling paths inert (see test-commandcode.sh for the
# same note). MM_MODE selects the fixture the stub serves for the Token Plan
# endpoint and the simulated HTTP status.
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
url=""
write_code=0
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -o)        out="${args[$((i + 1))]}" ;;
    -w)        write_code=1 ;;
    -H)        printf '%s\n' "${args[$((i + 1))]}" >> "${HDR_LOG:-/dev/null}" ;;
    http*)     url="${args[$i]}" ;;
  esac
done
status=200
case "$url" in
  *v1/token_plan/remains*)
    case "${MM_MODE:-valid}" in
      valid)       [ -n "$out" ] && cp "$MM_FIXTURE_DIR/minimax-token-plan-valid.json"        "$out"; status=200 ;;
      exhausted)   [ -n "$out" ] && cp "$MM_FIXTURE_DIR/minimax-token-plan-exhausted.json"    "$out"; status=200 ;;
      unavailable) [ -n "$out" ] && cp "$MM_FIXTURE_DIR/minimax-token-plan-unavailable.json"  "$out"; status=200 ;;
      malformed)   [ -n "$out" ] && cp "$MM_FIXTURE_DIR/minimax-token-plan-malformed.json"    "$out"; status=200 ;;
      bad_status)  [ -n "$out" ] && printf '%s' '{"base_resp":{"status_code":1,"status_msg":"plan quota exceeded"}}' >"$out"; status=200 ;;
      server_500)  [ -n "$out" ] && printf '' > "$out"; status=500 ;;
      empty_200)   [ -n "$out" ] && printf '' > "$out"; status=200 ;;
    esac
    ;;
  *v1/models*)
    status=200
    ;;
esac
if [ "$write_code" -eq 1 ]; then printf '%s' "$status"; fi
exit 0
STUB
chmod +x "$TMP/bin/curl"

run() {
  PATH="$TMP/bin:$PATH" \
  HDR_LOG="$HDR_LOG" \
  MM_FIXTURE_DIR="$ROOT/tests/fixtures" \
  MM_MODE="${MM_MODE:-valid}" \
  "$@" "$ROOT/providers/get-provider-usage" minimax 2>/dev/null
}
fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. Dedicated MINIMAX_TOKEN_PLAN_KEY → Token Plan path with quota windows.
: > "$HDR_LOG"
out="$(MM_MODE=valid run env -u MINIMAX_API_KEY MINIMAX_TOKEN_PLAN_KEY=sk-cp-plan)"
[ "$(jq -r '.[0].source'                          <<<"$out")" = "minimax-token-plan" ]   || fail "source token-plan"
[ "$(jq -r '.[0].usage.primary.windowMinutes'     <<<"$out")" = "300" ]                 || fail "5h minutes"
[ "$(jq -r '.[0].usage.primary.resetDescription'  <<<"$out")" = "null" ]                || fail "5h label (must be null for known 5h window)"
[ "$(jq -r '.[0].usage.primary.usedPercent|floor' <<<"$out")" = "27" ]                 || fail "5h percent (100-73)"
[ "$(jq -r '.[0].usage.secondary.windowMinutes'   <<<"$out")" = "10080" ]               || fail "weekly minutes"
[ "$(jq -r '.[0].usage.secondary.usedPercent|floor' <<<"$out")" = "9" ]                || fail "weekly percent (100-91)"
# resetsAt from end_time=1789480800000ms → 2026-09-15T14:00:00Z (UTC), regardless of TZ
[ "$(jq -r '.[0].usage.primary.resetsAt'          <<<"$out")" = "$(TZ=UTC jq -r '1789480800000 / 1000 | todateiso8601' <<<'null')" ] || fail "5h reset ms→ISO"
[ "$(jq -r '.[0].usage.identity.loginMethod'      <<<"$out")" = "subscription-key" ]   || fail "login method"
[ "$(jq -r '.[0].credits.remaining'               <<<"$out")" = "Token Plan" ]          || fail "credits label"
grep -q '^Authorization: Bearer sk-cp-plan$' "$HDR_LOG" || fail "auth header forwarded"

# 2. Back-compat: sk-cp MINIMAX_API_KEY alone still gets the Token Plan path.
: > "$HDR_LOG"
out="$(MM_MODE=valid run env -u MINIMAX_TOKEN_PLAN_KEY MINIMAX_API_KEY=sk-cp-legacy)"
[ "$(jq -r '.[0].source'                          <<<"$out")" = "minimax-token-plan" ] || fail "back-compat source"
[ "$(jq -r '.[0].usage.primary.usedPercent|floor' <<<"$out")" = "27" ]                || fail "back-compat 5h percent"
grep -q '^Authorization: Bearer sk-cp-legacy$' "$HDR_LOG" || fail "back-compat auth header"

# 3. MINIMAX_TOKEN_PLAN_KEY takes precedence over MINIMAX_API_KEY.
: > "$HDR_LOG"
out="$(MM_MODE=valid run env MINIMAX_TOKEN_PLAN_KEY=sk-cp-primary MINIMAX_API_KEY=sk-cp-secondary)"
grep -q '^Authorization: Bearer sk-cp-primary$' "$HDR_LOG" || fail "priority — primary key wins"
[ "$(jq -r '.[0].source'                          <<<"$out")" = "minimax-token-plan" ] || fail "priority source"

# 4. Pay-as-you-go sk-api MINIMAX_API_KEY stays on /v1/models (auth-only).
: > "$HDR_LOG"
out="$(MM_MODE=valid run env -u MINIMAX_TOKEN_PLAN_KEY MINIMAX_API_KEY=sk-api-payg)"
[ "$(jq -r '.[0].source'                          <<<"$out")" = "minimax-api" ]        || fail "PAYG source"
grep -q '^Authorization: Bearer sk-api-payg$' "$HDR_LOG" || fail "PAYG auth header"
# Auth-only shape: no quotas, just an informational card with the dashboard link.
[ "$(jq -r '.[0].usage.primary.usedPercent'        <<<"$out")" = "0" ]                 || fail "PAYG primary should be 0 (informational)"

# 5. status=2 (exhausted) → 100% used for both windows.
out="$(MM_MODE=exhausted run env -u MINIMAX_API_KEY MINIMAX_TOKEN_PLAN_KEY=sk-cp-plan)"
[ "$(jq -r '.[0].source'                          <<<"$out")" = "minimax-token-plan" ] || fail "exhausted source"
[ "$(jq -r '.[0].usage.primary.usedPercent'       <<<"$out")" = "100" ]               || fail "exhausted primary"
[ "$(jq -r '.[0].usage.secondary.usedPercent'     <<<"$out")" = "100" ]               || fail "exhausted secondary"

# 6. Genuinely unavailable bucket (status=3 with zero totals) must NOT silently
#    render as `Unlimited` — that's how we would visually claim a model bucket
#    that is not actually part of the plan. The adapter must surface a
#    provider error instead.
out="$(MM_MODE=unavailable run env -u MINIMAX_API_KEY MINIMAX_TOKEN_PLAN_KEY=sk-cp-plan)"
[ "$(jq -r '.[0].error.kind'                      <<<"$out")" = "provider" ]          || fail "unavailable bucket must error"

# 7. Empty / malformed model_remains → provider error, never 0% usage.
out="$(MM_MODE=malformed run env -u MINIMAX_API_KEY MINIMAX_TOKEN_PLAN_KEY=sk-cp-plan)"
[ "$(jq -r '.[0].error.kind'                      <<<"$out")" = "provider" ]          || fail "malformed must error"
[ "$(jq -r '.[0].usage'                           <<<"$out")" = "null" ]              || fail "malformed must not emit a usage object"

# 8. API-level error (base_resp.status_code != 0) → provider error.
out="$(MM_MODE=bad_status run env -u MINIMAX_API_KEY MINIMAX_TOKEN_PLAN_KEY=sk-cp-plan)"
[ "$(jq -r '.[0].error.kind'                      <<<"$out")" = "provider" ]          || fail "API-level error must error"
[ "$(jq -r '.[0].error.message'                   <<<"$out")" = "plan quota exceeded" ] || fail "API-level error message surfacing"

# 9. Network-level 500 → provider error, no quota payload.
out="$(MM_MODE=server_500 run env -u MINIMAX_API_KEY MINIMAX_TOKEN_PLAN_KEY=sk-cp-plan)"
[ "$(jq -r '.[0].error.kind'                      <<<"$out")" = "provider" ]          || fail "500 must error"

# 10. 200 OK with empty body → provider error (not "0% used" success).
out="$(MM_MODE=empty_200 run env -u MINIMAX_API_KEY MINIMAX_TOKEN_PLAN_KEY=sk-cp-plan)"
[ "$(jq -r '.[0].error.kind'                      <<<"$out")" = "provider" ]          || fail "empty body must error"

# 11. No credential at all → provider error naming both env vars.
out="$(run env -u MINIMAX_API_KEY -u MINIMAX_TOKEN_PLAN_KEY)"
[ "$(jq -r '.[0].error.kind'                      <<<"$out")" = "provider" ]          || fail "no-credentials kind"
[ "$(jq -r '.[0].error.message'                   <<<"$out")" = "MINIMAX_API_KEY or MINIMAX_TOKEN_PLAN_KEY is not set." ] || fail "no-credentials message"

# 12. Health check recognises MINIMAX_TOKEN_PLAN_KEY alone.
health="$(MINIMAX_TOKEN_PLAN_KEY=sk-cp-plan "$ROOT/providers/get-provider-health" minimax 2>/dev/null)"
[ "$(jq -r '.[0].status'                          <<<"$health")" = "ready" ]           || fail "Token Plan key health"
[ "$(jq -r '.[0].detail'                          <<<"$health")" = "Configured" ]      || fail "Token Plan key health detail"

# 13. Health check accepts the legacy sk-cp MINIMAX_API_KEY too.
health="$(MINIMAX_API_KEY=sk-cp-legacy "$ROOT/providers/get-provider-health" minimax 2>/dev/null)"
[ "$(jq -r '.[0].status'                          <<<"$health")" = "ready" ]           || fail "back-compat sk-cp health"

# 14. Health check still recognises sk-api PAYG keys.
health="$(MINIMAX_API_KEY=sk-api-payg "$ROOT/providers/get-provider-health" minimax 2>/dev/null)"
[ "$(jq -r '.[0].status'                          <<<"$health")" = "ready" ]           || fail "PAYG key health"

# 15. Health check reports both env vars when neither is set.
health="$(env -u MINIMAX_API_KEY -u MINIMAX_TOKEN_PLAN_KEY "$ROOT/providers/get-provider-health" minimax 2>/dev/null)"
[ "$(jq -r '.[0].status'                          <<<"$health")" = "missing" ]         || fail "no-credentials health status"
[ "$(jq -r '.[0].detail'                          <<<"$health")" = "MINIMAX_API_KEY or MINIMAX_TOKEN_PLAN_KEY" ] || fail "no-credentials health detail"

echo "OK: test-minimax-token-plan"
