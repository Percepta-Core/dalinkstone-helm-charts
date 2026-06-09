#!/usr/bin/env bash
# scripts/azure-oss-setup/test/infra/fresh-install-validate.sh
# Asserts a freshly-installed Azure OSS Daytona deployment is fully healthy.
# Run AFTER up.sh completes and ~3 minutes after to give the runner time to
# reach READY and cert-manager time to issue the Let's Encrypt cert.
#
# Usage:
#   bash scripts/azure-oss-setup/test/infra/fresh-install-validate.sh
#
# Exit codes:
#   0 — every assertion passed; cluster is ready for sandbox creation
#   1 — at least one assertion failed; prints diagnostic + names what to fix
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../_lib/common.sh
source "$REPO_ROOT/scripts/_lib/common.sh"
# shellcheck source=../../../_lib/infra-test.sh
source "$REPO_ROOT/scripts/_lib/infra-test.sh"

STATE_DIR="$REPO_ROOT/scripts/azure-oss-setup/.state"
NS="${NS:-daytona}"

if [[ -f "$STATE_DIR/oss-secrets.env" ]]; then
  set -a; . "$STATE_DIR/oss-secrets.env"; set +a
fi
if [[ -f "$STATE_DIR/prompts.env" ]]; then
  set -a; . "$STATE_DIR/prompts.env"; set +a
fi

FAIL=0

check() {
  local label="$1"; shift
  if "$@"; then
    echo "PASS [$label]"
  else
    echo "FAIL [$label]"
    FAIL=1
  fi
}

omc::log INFO "=== Fresh-install validation: namespace=$NS ==="

# 1. Core pods Ready
check "api pod Ready"        omc::infra::wait_for_pods_ready "$NS" "app.kubernetes.io/component=api"            60
check "proxy pod Ready"      omc::infra::wait_for_pods_ready "$NS" "app.kubernetes.io/component=proxy"          60
check "runner pod Ready"     omc::infra::wait_for_pods_ready "$NS" "app.kubernetes.io/component=runner"         60
check "runnermanager Ready"  omc::infra::wait_for_pods_ready "$NS" "app.kubernetes.io/component=runnermanager"  60
check "postgres Ready"       omc::infra::wait_for_pods_ready "$NS" "app.kubernetes.io/name=postgresql"          60

# 2. Sandbox node pool exists
NODE_COUNT="$(omc::infra::get_sandbox_nodes | grep -c .)"
if [[ "$NODE_COUNT" -ge 1 ]]; then
  echo "PASS [sandbox node count=$NODE_COUNT]"
else
  echo "FAIL [no sandbox nodes — label daytona-sandbox-c=true missing on any node]"
  FAIL=1
fi

# 3. Token wiring (chart-side contract)
check "DEFAULT_RUNNER_API_KEY == runner API_TOKEN" omc::infra::assert_token_match "$NS"

# 4. DB has at least one READY runner in region=us
if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
  echo "FAIL [POSTGRES_PASSWORD not set — sourced .state/oss-secrets.env missing]"
  FAIL=1
else
  if omc::infra::wait_runner_ready "$NS" "us" 180; then
    echo "PASS [runner state=ready in region=us]"
  else
    echo "FAIL [no READY runner in region=us within 180s]"
    FAIL=1
  fi
fi

# 5. Cert is real (cert-manager issued, not nginx fake)
if [[ -n "${BASE_DOMAIN:-}" ]]; then
  CERT_NAME="${BASE_DOMAIN}-tls"
  if kubectl -n "$NS" get certificate "$CERT_NAME" >/dev/null 2>&1; then
    check "Certificate $CERT_NAME Ready" omc::infra::wait_certificate_ready "$NS" "$CERT_NAME" 300
  else
    echo "SKIP [no Certificate resource named $CERT_NAME — DNS-01 may not be configured]"
  fi
  check "TLS cert at $BASE_DOMAIN is non-fake" omc::infra::assert_cert_is_real "$BASE_DOMAIN"
else
  echo "SKIP [TLS checks — BASE_DOMAIN not set in $STATE_DIR/prompts.env]"
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  omc::log INFO "FRESH-INSTALL VALIDATION PASSED — cluster is ready for sandbox creation"
  exit 0
fi
omc::log ERROR "FRESH-INSTALL VALIDATION FAILED — $FAIL assertion(s) failed"
omc::log ERROR "Run: bash scripts/azure-oss-setup/test/infra/diagnose.sh"
exit 1
