#!/usr/bin/env bash
# smoke.sh — black-box checks against a deployed haiguitang proxy.
#
# Verifies:
#   1. /api/health responds 200 with ok=true
#   2. /api/v1/messages rejects unauthenticated requests with 401 + missing_auth
#   3. /api/v1/messages rejects malformed tokens with 401
#   4. /api/v1/generate-puzzle rejects unauthenticated requests with 401
#
# Does NOT exercise the happy path of the protected endpoints — that requires
# a real Firebase ID Token. The point of smoke is to confirm the proxy is
# alive and the auth gate is wired up.
#
# Usage:
#   ./smoke.sh https://haiguitang.vercel.app
#   BASE_URL=https://haiguitang.vercel.app ./smoke.sh
#
# Exits non-zero if any check fails.

set -u

BASE_URL="${1:-${BASE_URL:-}}"
if [[ -z "$BASE_URL" ]]; then
  echo "usage: $0 <base-url>   (or set BASE_URL env var)" >&2
  exit 2
fi
BASE_URL="${BASE_URL%/}"   # strip trailing slash

# ─── colors (skip if not a tty) ───────────────────────────────────────────────
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; DIM='\033[2m'; RESET='\033[0m'
else
  GREEN=''; RED=''; DIM=''; RESET=''
fi

PASS=0
FAIL=0

# Print a labeled check result. $1 = label, $2 = ok? (0/1), $3 = detail
report() {
  local label="$1"; local ok="$2"; local detail="$3"
  if [[ "$ok" -eq 0 ]]; then
    PASS=$((PASS + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  ${RED}✗${RESET} %s\n      %s\n" "$label" "$detail"
  fi
}

# curl wrapper: prints "STATUS<TAB>BODY". -s silent, -w "%{http_code}" trick:
# we write the status to stderr-isolated stdout in a known format by using
# a separator that won't appear in JSON.
http() {
  local method="$1"; local path="$2"; shift 2
  local sep=$'\x1f'   # ASCII unit separator
  curl -sS -X "$method" "$BASE_URL$path" \
       -w "${sep}%{http_code}" \
       "$@"
}

# Parse the combined "BODY<US>STATUS" payload.
parse_status() { echo "$1" | awk -F$'\x1f' '{print $NF}'; }
parse_body()   { echo "$1" | awk -F$'\x1f' 'BEGIN{ORS=""} {for(i=1;i<NF;i++){print $i; if(i<NF-1)print "\x1f"}}'; }

printf "→ smoke testing %s\n\n" "$BASE_URL"

# ─── 1. health ───────────────────────────────────────────────────────────────
printf "${DIM}[1/4] GET /api/health${RESET}\n"
out=$(http GET "/api/health")
status=$(parse_status "$out")
body=$(parse_body "$out")
if [[ "$status" == "200" ]] && echo "$body" | grep -q '"ok":true'; then
  report "200 + ok:true" 0 ""
else
  report "health endpoint" 1 "got status=$status body=$body"
fi

# ─── 2. messages, no auth ────────────────────────────────────────────────────
printf "${DIM}[2/4] POST /api/v1/messages  (no Authorization)${RESET}\n"
out=$(http POST "/api/v1/messages" \
       -H "Content-Type: application/json" \
       -d '{"model":"x","max_tokens":1,"messages":[]}')
status=$(parse_status "$out")
body=$(parse_body "$out")
if [[ "$status" == "401" ]] && echo "$body" | grep -q '"code":"missing_auth"'; then
  report "401 + missing_auth" 0 ""
else
  report "messages should reject missing auth" 1 "got status=$status body=$body"
fi

# ─── 3. messages, garbage token ──────────────────────────────────────────────
printf "${DIM}[3/4] POST /api/v1/messages  (Bearer garbage)${RESET}\n"
out=$(http POST "/api/v1/messages" \
       -H "Content-Type: application/json" \
       -H "Authorization: Bearer not-a-real-jwt" \
       -d '{"model":"x","max_tokens":1,"messages":[]}')
status=$(parse_status "$out")
body=$(parse_body "$out")
# Either invalid_token (malformed) or verification_failed is acceptable —
# both prove the verifier ran and refused.
if [[ "$status" == "401" ]] && echo "$body" | grep -qE '"code":"(invalid_token|verification_failed|unknown_kid|auth_failed)"'; then
  report "401 + token rejected" 0 ""
else
  report "messages should reject garbage token" 1 "got status=$status body=$body"
fi

# ─── 4. generate-puzzle, no auth ─────────────────────────────────────────────
printf "${DIM}[4/4] POST /api/v1/generate-puzzle  (no Authorization)${RESET}\n"
out=$(http POST "/api/v1/generate-puzzle" \
       -H "Content-Type: application/json" \
       -d '{"idea":"x"}')
status=$(parse_status "$out")
body=$(parse_body "$out")
if [[ "$status" == "401" ]] && echo "$body" | grep -q '"code":"missing_auth"'; then
  report "401 + missing_auth" 0 ""
else
  report "generate-puzzle should reject missing auth" 1 "got status=$status body=$body"
fi

# ─── summary ─────────────────────────────────────────────────────────────────
echo
if [[ "$FAIL" -eq 0 ]]; then
  printf "${GREEN}all %d checks passed.${RESET}\n" "$PASS"
  exit 0
else
  printf "${RED}%d passed, %d failed.${RESET}\n" "$PASS" "$FAIL"
  exit 1
fi
