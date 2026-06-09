#!/usr/bin/env bash
# scripts/azure-oss-setup/test/infra/diagnose.sh
# Comprehensive live-cluster diagnostic for a self-hosted OSS Daytona deployment.
# Replaces the earlier ad-hoc kubectl-pasta with stable, correctly-named queries.
#
# Usage:
#   bash scripts/azure-oss-setup/test/infra/diagnose.sh
#
# Prerequisites:
#   - kubectl context pointing at the AKS cluster
#   - scripts/azure-oss-setup/.state/oss-secrets.env exists (for POSTGRES_PASSWORD)
#   - scripts/azure-oss-setup/.state/prompts.env exists (for BASE_DOMAIN)
#
# Exit codes:
#   0 — diagnostic ran (no opinion about whether the cluster is healthy)
#   1 — could not reach the cluster or load state
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
  set -a
  # shellcheck source=/dev/null
  . "$STATE_DIR/oss-secrets.env"
  set +a
else
  omc::log WARN "$STATE_DIR/oss-secrets.env missing; DB queries will fail unless POSTGRES_PASSWORD is set"
fi
if [[ -f "$STATE_DIR/prompts.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$STATE_DIR/prompts.env"
  set +a
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  omc::die "kubectl cannot reach the cluster. Check KUBECONFIG."
fi

echo "================================================================"
echo "Daytona OSS live diagnostic — namespace=$NS"
echo "================================================================"

echo ""
echo "=== [1/8] Pod states ==="
kubectl -n "$NS" get pods -o wide

echo ""
echo "=== [2/8] Sandbox nodes (label daytona-sandbox-c=true) ==="
kubectl get nodes -l daytona-sandbox-c=true -o wide

echo ""
echo "=== [3/8] API pod env: DEFAULT_RUNNER_* + RUNNER_MANAGER_API_KEY ==="
kubectl -n "$NS" exec deploy/daytona-api -- env 2>/dev/null \
  | grep -iE "DEFAULT_RUNNER|DEFAULT_REGION|RUNNER_MANAGER_API_KEY" \
  | sort \
  || echo "  (api pod env query failed)"

echo ""
echo "=== [4/8] Runner pod env: API_TOKEN + URLs + NODE_NAME ==="
RUNNER_POD="$(omc::infra::get_pod "$NS" "app.kubernetes.io/component=runner")"
if [[ -n "$RUNNER_POD" ]]; then
  kubectl -n "$NS" exec "$RUNNER_POD" -c runner -- env 2>/dev/null \
    | grep -iE "API_TOKEN|SERVER_URL|DAYTONA_API_URL|NODE_NAME|DAYTONA_RUNNER" \
    | sort
else
  echo "  (no runner pod found — check sandbox node label/taint)"
fi

echo ""
echo "=== [5/8] runner table (the truth) ==="
omc::infra::query_runners_table "$NS" || echo "  (DB query failed)"

echo ""
echo "=== [6/8] region table (raw — schema may vary by daytona version) ==="
omc::infra::psql "$NS" "SELECT * FROM region LIMIT 5;" 2>&1 \
  || echo "  (region table query failed — table may not exist on this api version)"

echo ""
echo "=== [7/8] Token wiring assertion (api DEFAULT_RUNNER_API_KEY == runner API_TOKEN) ==="
if omc::infra::assert_token_match "$NS"; then
  echo "  PASS"
else
  echo "  FAIL — runner cannot authenticate to api"
fi

echo ""
echo "=== [8/8] TLS cert at base domain ==="
if [[ -n "${BASE_DOMAIN:-}" ]]; then
  ISSUER="$(omc::infra::probe_serving_cert_issuer "$BASE_DOMAIN")"
  if [[ -z "$ISSUER" ]]; then
    echo "  Could not probe TLS at $BASE_DOMAIN (DNS not resolving / unreachable)"
  else
    echo "  Cert issuer for $BASE_DOMAIN: $ISSUER"
    if echo "$ISSUER" | grep -qiE "fake certificate|kubernetes ingress controller"; then
      echo "  FAIL — nginx-ingress fake cert is being served (cert-manager has not issued LE cert)"
    elif echo "$ISSUER" | grep -qiE "let's encrypt|R10|R11"; then
      echo "  PASS — Let's Encrypt cert active"
    else
      echo "  INFO — cert is from a different CA (probably Cloudflare or operator-supplied)"
    fi
  fi
else
  echo "  Skipping cert probe — BASE_DOMAIN not set in $STATE_DIR/prompts.env"
fi

echo ""
echo "=== Recent runner-manager activity (last 20 lines) ==="
RM_POD="$(omc::infra::get_pod "$NS" "app.kubernetes.io/component=runnermanager")"
if [[ -n "$RM_POD" ]]; then
  kubectl -n "$NS" logs "$RM_POD" --tail=20 2>&1
else
  echo "  (no runnermanager pod found)"
fi

echo ""
echo "=== Recent runner binary log lines mentioning api/poll/health/error ==="
if [[ -n "$RUNNER_POD" ]]; then
  kubectl -n "$NS" logs "$RUNNER_POD" -c runner --tail=100 2>/dev/null \
    | grep -iE "poll|health|api|error|401|503|register" \
    | tail -20 \
    || echo "  (no matching log lines in last 100)"
else
  echo "  (no runner pod found)"
fi

echo ""
echo "================================================================"
echo "Diagnostic complete. Common interpretation:"
echo "  - empty [5/8] runner table → api bootstrap skipped (DEFAULT_RUNNER_NAME missing)"
echo "  - runner row state=initializing → runner binary not heartbeating (check [8] log)"
echo "  - runner row state=ready, availabilityScore=0 → Docker/Sysbox on host failed"
echo "  - [7/8] token mismatch → re-run helm upgrade with the latest chart fix"
echo "  - [8/8] fake cert → re-run up.sh with CLOUDFLARE_API_TOKEN for DNS-01 issuer"
echo "================================================================"
