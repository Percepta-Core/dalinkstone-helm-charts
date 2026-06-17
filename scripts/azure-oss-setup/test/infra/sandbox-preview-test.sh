#!/usr/bin/env bash
# scripts/azure-oss-setup/test/infra/sandbox-preview-test.sh
# Live verification that sandbox creation AND preview URLs work end-to-end:
#   1. POST /api/sandbox (public, default snapshot) with ADMIN_API_KEY
#   2. poll until state=started
#   3. toolbox-exec a tiny HTTP server on port 3000 inside the sandbox
#   4. curl the public preview URL https://3000-<id>.<BASE_DOMAIN> through
#      the wildcard ingress -> proxy -> runner -> sandbox chain
#   5. delete the sandbox
#
# Self-signed TLS mode is handled with curl -k (TLS_MODE from prompts.env).
#
# Exit codes: 0 = preview URL served sandbox content; 1 = any step failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../_lib/common.sh
source "$REPO_ROOT/scripts/_lib/common.sh"

STATE_DIR="$REPO_ROOT/scripts/azure-oss-setup/.state"
NS="${NS:-daytona}"

if [[ -f "$STATE_DIR/prompts.env" ]]; then
  set -a; . "$STATE_DIR/prompts.env"; set +a
fi
if [[ -f "$STATE_DIR/oss-secrets.env" ]]; then
  set -a; . "$STATE_DIR/oss-secrets.env"; set +a
fi

: "${BASE_DOMAIN:?BASE_DOMAIN required (prompts.env)}"
: "${ADMIN_API_KEY:?ADMIN_API_KEY required (oss-secrets.env)}"

API="https://${BASE_DOMAIN}/api"
CURL=(curl -sS --max-time 30)
if [[ "${TLS_MODE:-}" == "self-signed" ]]; then
  CURL+=(-k)
fi
AUTH=(-H "Authorization: Bearer ${ADMIN_API_KEY}")

omc::log INFO "=== Sandbox + preview URL live test against $API ==="

omc::log INFO "[1/5] Creating public sandbox from default snapshot..."
create_resp="$("${CURL[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -X POST "$API/sandbox" -d '{"public": true}')"
SANDBOX_ID="$(echo "$create_resp" | jq -r '.id // empty')"
if [[ -z "$SANDBOX_ID" ]]; then
  omc::log ERROR "Sandbox create failed. Response: $(echo "$create_resp" | head -c 600)"
  exit 1
fi
omc::log INFO "Sandbox created: $SANDBOX_ID"

cleanup() {
  omc::log INFO "[5/5] Deleting sandbox $SANDBOX_ID..."
  "${CURL[@]}" "${AUTH[@]}" -X DELETE "$API/sandbox/$SANDBOX_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

omc::log INFO "[2/5] Waiting up to 5m for sandbox state=started..."
elapsed=0 state=""
while [[ $elapsed -lt 300 ]]; do
  state="$("${CURL[@]}" "${AUTH[@]}" "$API/sandbox/$SANDBOX_ID" | jq -r '.state // empty')"
  if [[ "$state" == "started" ]]; then break; fi
  if [[ "$state" == "error" || "$state" == "build_failed" ]]; then
    omc::log ERROR "Sandbox entered state=$state"
    "${CURL[@]}" "${AUTH[@]}" "$API/sandbox/$SANDBOX_ID" | jq '.' | head -40
    exit 1
  fi
  sleep 10; elapsed=$((elapsed + 10))
done
if [[ "$state" != "started" ]]; then
  omc::log ERROR "Sandbox not started after 5m (state=$state)"
  exit 1
fi
omc::log INFO "Sandbox started"

omc::log INFO "[3/5] Starting HTTP server on :3000 inside the sandbox (toolbox exec)..."
exec_resp="$("${CURL[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -X POST "$API/toolbox/$SANDBOX_ID/toolbox/process/execute" \
  -d '{"command": "sh -c \"echo daytona-preview-ok > /tmp/index.html && cd /tmp && nohup python3 -m http.server 3000 >/dev/null 2>&1 & sleep 1; echo started\""}')"
if ! echo "$exec_resp" | jq -e '.exitCode == 0' >/dev/null 2>&1; then
  omc::log WARN "toolbox exec response: $(echo "$exec_resp" | head -c 400)"
  omc::log WARN "Continuing — preview routing can still be proven by proxy response"
fi

omc::log INFO "[4/5] Fetching preview URL for port 3000..."
preview_resp="$("${CURL[@]}" "${AUTH[@]}" "$API/sandbox/$SANDBOX_ID/ports/3000/preview-url")"
PREVIEW_URL="$(echo "$preview_resp" | jq -r '.url // empty')"
if [[ -z "$PREVIEW_URL" ]]; then
  omc::log ERROR "No preview URL returned: $(echo "$preview_resp" | head -c 400)"
  exit 1
fi
omc::log INFO "Preview URL: $PREVIEW_URL"

# Expected shape: https://3000-<sandboxId>.<BASE_DOMAIN>
if ! echo "$PREVIEW_URL" | grep -q "3000-.*\.${BASE_DOMAIN}"; then
  omc::log ERROR "Preview URL shape unexpected (want 3000-<id>.${BASE_DOMAIN})"
  exit 1
fi

ok=0
for _ in 1 2 3 4 5 6; do
  body="$("${CURL[@]}" "$PREVIEW_URL" 2>/dev/null || true)"
  if echo "$body" | grep -q "daytona-preview-ok\|Directory listing"; then
    ok=1; break
  fi
  sleep 5
done
if [[ "$ok" -eq 1 ]]; then
  omc::log INFO "PASS — preview URL served sandbox content through wildcard ingress -> proxy -> runner"
  exit 0
fi
omc::log ERROR "Preview URL did not serve sandbox content. Last response: $(echo "${body:-}" | head -c 400)"
exit 1
