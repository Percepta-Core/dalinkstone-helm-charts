#!/usr/bin/env bash
# scripts/azure-oss-setup/e2e.sh — minimal smoke test for the OSS Azure deploy.
# Different from the BYOC e2e.sh: this one targets the self-hosted API at
# https://${BASE_DOMAIN} (not Daytona Cloud), and the SDK ADMIN credentials
# come from the operator (the chart's first-user is created via the API's
# init flow on first dashboard visit).
#
# This script ONLY validates infrastructure-level reachability. Full
# end-to-end sandbox-create testing is done by the operator via the dashboard
# at https://${BASE_DOMAIN}.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$SCRIPT_DIR/.state"
PROMPTS_FILE="$STATE_DIR/prompts.env"

if [[ ! -f "$PROMPTS_FILE" ]]; then
  echo "ERROR: $PROMPTS_FILE missing — run up.sh first." >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$PROMPTS_FILE"

: "${BASE_DOMAIN:?BASE_DOMAIN must be set}"
API_URL="https://${BASE_DOMAIN}"
HARBOR_URL="https://harbor.${BASE_DOMAIN}"
DEX_URL="https://dex.${BASE_DOMAIN}"

echo "=== Daytona OSS smoke test against $API_URL ==="
echo ""

echo "[1/4] kubectl: daytona namespace pods Ready?"
NOT_READY="$(kubectl -n daytona get pods --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {print $1}' | wc -l | tr -d ' ')"
if [[ "$NOT_READY" -eq 0 ]]; then
  echo "  ✅ all pods Running/Completed"
else
  echo "  ⚠️  $NOT_READY pods not Running:"
  kubectl -n daytona get pods --no-headers | awk '$3 != "Running" && $3 != "Completed"'
fi
echo ""

echo "[2/4] DNS resolution for $BASE_DOMAIN + wildcard?"
if host "$BASE_DOMAIN" >/dev/null 2>&1; then
  echo "  ✅ $BASE_DOMAIN resolves"
else
  echo "  ❌ $BASE_DOMAIN does NOT resolve — create the A/CNAME record"
fi
if host "test-sandbox.${BASE_DOMAIN}" >/dev/null 2>&1; then
  echo "  ✅ *.$BASE_DOMAIN wildcard resolves"
else
  echo "  ❌ wildcard does NOT resolve — create the *.<base> record"
fi
echo ""

echo "[3/4] API HTTPS reachability?"
if curl -fsS -o /dev/null -w "  %{http_code}\n" --max-time 15 "${API_URL}/health" 2>/dev/null; then
  echo "  ✅ $API_URL/health reachable"
elif curl -fsS -o /dev/null -w "  %{http_code}\n" --max-time 15 "${API_URL}/" 2>/dev/null; then
  echo "  ✅ $API_URL reachable (no /health endpoint)"
else
  echo "  ❌ $API_URL not reachable — check cert-manager + ingress-nginx logs"
fi
echo ""

echo "[4/4] Harbor + Dex reachability?"
curl -fsS -o /dev/null -w "  Harbor: %{http_code}\n" --max-time 15 "${HARBOR_URL}/api/v2.0/health" 2>/dev/null || echo "  Harbor: not reachable"
curl -fsS -o /dev/null -w "  Dex:    %{http_code}\n" --max-time 15 "${DEX_URL}/healthz" 2>/dev/null || echo "  Dex:    not reachable"
echo ""

echo "=== Manual verification next ==="
echo "  1. Open $API_URL in a browser"
echo "  2. Walk through the first-time admin setup"
echo "  3. Open $HARBOR_URL — log in as 'admin' with the generated HARBOR_ADMIN_PASSWORD"
echo "  4. Create a sandbox via the dashboard at $API_URL"
echo ""

if command -v python3 >/dev/null 2>&1; then
  echo "=== Optional: SDK install ==="
  echo "  pip install 'daytona==0.183.*'"
  echo "  Then point the SDK at $API_URL"
fi
