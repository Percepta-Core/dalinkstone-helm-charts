#!/usr/bin/env bash
# scripts/azure-oss-setup/test/infra/recycle-node.sh
# Asserts that recycling a sandbox node produces a NEW runner that reaches
# state=ready in the api DB within a bounded timeout. This is the canonical
# infra regression: after `az aks nodepool delete-machines`, the chart's
# DaemonSet + runner-manager + api auth chain must converge again.
#
# Usage:
#   bash scripts/azure-oss-setup/test/infra/recycle-node.sh           # recycle FIRST sandbox node
#   NODE_TO_RECYCLE=aks-sandbox-XXX bash <this script>                # recycle a specific node
#
# Exit codes:
#   0 — node successfully recycled AND new runner reached state=ready
#   1 — recycle failed OR new runner did not converge in time
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../_lib/common.sh
source "$REPO_ROOT/scripts/_lib/common.sh"
# shellcheck source=../../../_lib/infra-test.sh
source "$REPO_ROOT/scripts/_lib/infra-test.sh"

STATE_DIR="$REPO_ROOT/scripts/azure-oss-setup/.state"
NS="${NS:-daytona}"

if [[ -f "$STATE_DIR/prompts.env" ]]; then
  set -a; . "$STATE_DIR/prompts.env"; set +a
else
  omc::die "$STATE_DIR/prompts.env missing — run up.sh first"
fi
if [[ -f "$STATE_DIR/oss-secrets.env" ]]; then
  set -a; . "$STATE_DIR/oss-secrets.env"; set +a
fi

: "${CLUSTER_NAME:?CLUSTER_NAME required (sourced from prompts.env)}"
: "${RESOURCE_GROUP:?RESOURCE_GROUP required}"

omc::need_cmd kubectl az
omc::log INFO "=== Node recycle infra test ==="
omc::log INFO "Cluster: $CLUSTER_NAME (rg: $RESOURCE_GROUP)"

# Baseline: capture current sandbox nodes
BEFORE_NODES="$(omc::infra::get_sandbox_nodes)"
BEFORE_COUNT="$(echo "$BEFORE_NODES" | grep -c .)"
if [[ "$BEFORE_COUNT" -lt 1 ]]; then
  omc::die "No sandbox nodes present — nothing to recycle"
fi
omc::log INFO "Baseline sandbox nodes ($BEFORE_COUNT): $(echo "$BEFORE_NODES" | tr '\n' ' ')"

# Baseline: READY runner count
BEFORE_READY="$(omc::infra::count_ready_runners "$NS" "${REGION_ID:-us}")"
omc::log INFO "Baseline READY runners in region=${REGION_ID:-us}: $BEFORE_READY"
if [[ "$BEFORE_READY" -lt 1 ]]; then
  omc::log WARN "No READY runners before recycle — recycle test isn't testing convergence-from-healthy"
fi

# Pick a node to recycle
TARGET_NODE="${NODE_TO_RECYCLE:-$(echo "$BEFORE_NODES" | head -1)}"
omc::log INFO "Target node: $TARGET_NODE"

# Recycle via the helper
omc::infra::aks_delete_node "$CLUSTER_NAME" "$RESOURCE_GROUP" "sandbox" "$TARGET_NODE"

# Wait for AKS to provision the replacement
NEW_NODE="$(omc::infra::wait_new_sandbox_node "$BEFORE_NODES" 600)" \
  || omc::die "AKS did not provision a replacement sandbox node within 10 min"

# New node must be Ready in K8s before we wait for the runner pod
omc::log INFO "Waiting up to 5m for new node $NEW_NODE to reach Ready..."
kubectl wait --for=condition=Ready "node/$NEW_NODE" --timeout=300s >/dev/null \
  || omc::die "Node $NEW_NODE not Ready within 5 min"

# Runner DaemonSet should schedule a pod on the new node within seconds
omc::log INFO "Waiting up to 3m for runner pod on $NEW_NODE..."
elapsed=0
while [[ $elapsed -lt 180 ]]; do
  new_pod="$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=runner \
    --field-selector "spec.nodeName=$NEW_NODE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [[ -n "$new_pod" ]]; then
    omc::log INFO "Runner pod on new node: $new_pod"
    break
  fi
  sleep 10
  elapsed=$((elapsed + 10))
done
[[ -n "$new_pod" ]] || omc::die "DaemonSet did not schedule a runner on $NEW_NODE in 3 min"

# Pod Ready
omc::log INFO "Waiting up to 10m for $new_pod to reach Ready (docker-installer takes time)..."
kubectl -n "$NS" wait --for=condition=Ready "pod/$new_pod" --timeout=600s \
  || omc::die "Runner pod $new_pod not Ready in 10 min"

# DB convergence: runner state=ready in region
omc::log INFO "Waiting up to 5m for a READY runner to register in DB..."
omc::infra::wait_runner_ready "$NS" "${REGION_ID:-us}" 300 \
  || omc::die "No READY runner in DB after node recycle within 5 min"

AFTER_READY="$(omc::infra::count_ready_runners "$NS" "${REGION_ID:-us}")"
omc::log INFO "After recycle READY runner count: $AFTER_READY (baseline was $BEFORE_READY)"

if [[ "$AFTER_READY" -lt "$BEFORE_READY" ]]; then
  omc::log ERROR "READY runner count regressed: $BEFORE_READY → $AFTER_READY"
  omc::infra::query_runners_table "$NS"
  exit 1
fi

omc::log INFO "PASS — node $TARGET_NODE recycled to $NEW_NODE, runner converged to READY"
exit 0
