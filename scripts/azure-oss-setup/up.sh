#!/usr/bin/env bash
# scripts/azure-oss-setup/up.sh — FULL self-hosted OSS Daytona on Azure AKS.
#
# Sister script to scripts/azure-setup/up.sh BUT uses the daytona MAIN chart
# (not daytona-region). Everything runs inside the AKS cluster:
#   - API server + Postgres + Redis + MinIO + Harbor + Dex (auth)
#   - Proxy + Runner DaemonSet + SSH gateway + Runner manager
# No Daytona Cloud control plane. No external rclone gateway (MinIO is in-cluster).
#
# Single interactive entrypoint:
#   1. prompts for cluster name, base domain, region, RG, ACME email
#   2. auto-generates Postgres / Redis / MinIO / Harbor passwords
#   3. creates resource group + AKS cluster (Workload Identity ready, Ubuntu 24.04)
#      + sandbox node pool with daytona-sandbox-c label + taint
#   4. updates kubeconfig
#   5. VERIFIES Ubuntu 24.04 on all AKS nodes + sandbox-labeled nodes (NO EXCEPTIONS)
#   6. namespace + ingress-nginx + cert-manager + Let's Encrypt ClusterIssuer
#   7. waits for LoadBalancer hostname, prints 2 DNS records (base + wildcard)
#   8. operator confirms DNS propagation
#   9. helm dependency build (postgres/redis/minio/harbor) + helm install daytona
#  10. prints API URL, dashboard URL, Harbor URL, sandbox URL pattern
#
# Same Ubuntu 24.04 + v0.184 + no-install.sh constraints as the BYOC azure-setup.
# See docs/byoc-overhaul/azure-oss.md (in this repo) for the test loop.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"
# shellcheck source=../_lib/sku-data.sh
source "$SCRIPT_DIR/../_lib/sku-data.sh"
# shellcheck source=../_lib/sku-azure.sh
source "$SCRIPT_DIR/../_lib/sku-azure.sh"

omc::need_cmd az kubectl helm envsubst yq jq openssl

STATE_DIR="$(omc::state_dir "$SCRIPT_DIR")"
PROMPTS_FILE="$STATE_DIR/prompts.env"
SECRETS_FILE="$STATE_DIR/oss-secrets.env"
VALUES_OUT="$STATE_DIR/values-oss.yaml"

if [[ -f "$PROMPTS_FILE" ]]; then
  omc::log INFO "Loading saved prompts from $PROMPTS_FILE"
  set -a
  # shellcheck source=/dev/null
  . "$PROMPTS_FILE"
  set +a
else
  unset CLUSTER_NAME BASE_DOMAIN CLUSTER_ISSUER_EMAIL CLUSTER_ISSUER TLS_MODE \
        AZURE_LOCATION RESOURCE_GROUP RUNNER_IMAGE_TAG AZURE_NODE_VM_SIZE
fi
if [[ -f "$SECRETS_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$SECRETS_FILE"
  set +a
fi

# === 1. Interactive prompts ==================================================
omc::log INFO "=== Daytona FULL OSS Self-Hosted: Azure AKS bring-up ==="
omc::prompt CLUSTER_NAME "Cluster name" "daytona-oss-$(date +%Y%m%d-%H%M%S)"
omc::prompt BASE_DOMAIN  "Public base DNS domain (e.g. daytona.mycompany.com)"
omc::prompt_choice TLS_MODE \
  "TLS strategy for the api/proxy/dex/harbor ingresses:
  cloudflare-dns01 = automatic Let's Encrypt via Cloudflare DNS-01 (handles wildcard SANs, recommended for prod)
  self-signed      = chart generates self-signed certs (browser warnings; dev/test only)
  manual           = operator pre-creates Secret named <baseDomain>-tls (advanced; you manage cert rotation)" \
  cloudflare-dns01 self-signed manual
omc::prompt AZURE_LOCATION "Azure region" "eastus"
omc::prompt RESOURCE_GROUP "Azure resource group" "${CLUSTER_NAME}-rg"
omc::prompt RUNNER_IMAGE_TAG \
  "Daytona image tag (applied to api/proxy/runner/runnermanager/ssh-gateway).
  Default is v0.184.0-k8s-oss.1-amd64, NOT .3. The .3 patch ships a runner-side
  bug where the v2 healthcheck goroutine sends ONE heartbeat after boot and then
  silently stops (container stays alive, restartCount=0, lastChecked frozen),
  which causes the api's 60s unresponsive-threshold check to flip the runner
  to UNRESPONSIVE permanently and triggers REMOVE_SNAPSHOT cleanup of the
  default snapshot. The .1 patch is the latest .3-incompatible-bug-free k8s-oss
  variant that exists for ALL 5 services (api/proxy/runner/runnermanager/ssh-gateway).
  daytona-runner-manager has no v0.183.x tags at all (its repo skips from v0.174.0
  straight to v0.184.0-k8s-oss.1-amd64), so a full v0.183 revert is impossible." \
  "v0.184.0-k8s-oss.1-amd64"

CLUSTER_ISSUER=""
if [[ "$TLS_MODE" == "cloudflare-dns01" ]]; then
  omc::prompt CLUSTER_ISSUER_EMAIL "Email for Let's Encrypt ClusterIssuer (used for cert expiry warnings)"
  omc::prompt_secret CLOUDFLARE_API_TOKEN \
    "Cloudflare API token (Zone:Read + Zone DNS:Edit scopes for ${BASE_DOMAIN}'s zone)"
  CLUSTER_ISSUER="letsencrypt-prod"
fi

{
  printf 'export CLUSTER_NAME=%q\n' "$CLUSTER_NAME"
  printf 'export BASE_DOMAIN=%q\n'  "$BASE_DOMAIN"
  printf 'export TLS_MODE=%q\n'     "$TLS_MODE"
  printf 'export CLUSTER_ISSUER_EMAIL=%q\n' "${CLUSTER_ISSUER_EMAIL:-}"
  printf 'export CLUSTER_ISSUER=%q\n' "$CLUSTER_ISSUER"
  printf 'export AZURE_LOCATION=%q\n' "$AZURE_LOCATION"
  printf 'export RESOURCE_GROUP=%q\n' "$RESOURCE_GROUP"
  printf 'export RUNNER_IMAGE_TAG=%q\n' "$RUNNER_IMAGE_TAG"
} > "$PROMPTS_FILE"
chmod 600 "$PROMPTS_FILE"

# === 2. Auto-generate subchart secrets (postgres/redis/minio/harbor/api) ====
if [[ ! -f "$SECRETS_FILE" ]]; then
  omc::log INFO "=== Step 2/10: Generating subchart secrets ==="
  POSTGRES_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
  REDIS_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
  MINIO_ROOT_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
  HARBOR_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
  {
    printf 'export POSTGRES_PASSWORD=%q\n'     "$POSTGRES_PASSWORD"
    printf 'export REDIS_PASSWORD=%q\n'        "$REDIS_PASSWORD"
    printf 'export MINIO_ROOT_PASSWORD=%q\n'   "$MINIO_ROOT_PASSWORD"
    printf 'export HARBOR_ADMIN_PASSWORD=%q\n' "$HARBOR_ADMIN_PASSWORD"
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
      printf 'export CLOUDFLARE_API_TOKEN=%q\n'  "$CLOUDFLARE_API_TOKEN"
    fi
  } > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
  omc::log INFO "Auto-generated subchart secrets -> $SECRETS_FILE (mode 0600)"
else
  omc::log INFO "Reusing existing subchart secrets from $SECRETS_FILE"
fi

# Append-if-missing secrets introduced after older state dirs were created.
# ADMIN_API_KEY: REQUIRED by the api at first boot (getOrThrow('admin.apiKey')
# has no in-code default; missing => bootstrap throw => CrashLoopBackOff).
# It becomes the Daytona Admin user's API key — also what e2e.sh / the SDK use.
if [[ -z "${ADMIN_API_KEY:-}" ]]; then
  ADMIN_API_KEY="dtn_admin_$(openssl rand -hex 20)"
  printf 'export ADMIN_API_KEY=%q\n' "$ADMIN_API_KEY" >> "$SECRETS_FILE"
  omc::log INFO "Generated ADMIN_API_KEY -> appended to $SECRETS_FILE"
fi
# Encryption-at-rest material (api encrypts stored secrets with these; the
# chart defaults are CHANGE_ME placeholders).
if [[ -z "${ENCRYPTION_KEY:-}" ]]; then
  ENCRYPTION_KEY="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
  printf 'export ENCRYPTION_KEY=%q\n' "$ENCRYPTION_KEY" >> "$SECRETS_FILE"
  omc::log INFO "Generated ENCRYPTION_KEY -> appended to $SECRETS_FILE"
fi
if [[ -z "${ENCRYPTION_SALT:-}" ]]; then
  ENCRYPTION_SALT="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
  printf 'export ENCRYPTION_SALT=%q\n' "$ENCRYPTION_SALT" >> "$SECRETS_FILE"
  omc::log INFO "Generated ENCRYPTION_SALT -> appended to $SECRETS_FILE"
fi

# === 3. Resource group + AKS =================================================
omc::log INFO "=== Step 3/10: Resource group + AKS ==="

# Preflight: ensure required Azure resource providers are registered on this
# subscription. New subscriptions ship with everything Unregistered.
omc::az_register_providers \
  Microsoft.ContainerService \
  Microsoft.Network \
  Microsoft.Compute \
  Microsoft.Storage

# Quota-aware VM size: 3 system + 1 sandbox nodes share this SKU = 4 vCPU * 4 = 16 vCPU total
if [[ -z "${AZURE_NODE_VM_SIZE:-}" ]]; then
  AZURE_NODE_VM_SIZE="$(omc::azure_select_vm_size "$AZURE_LOCATION" 16 OMC_INSTANCE_TYPE)"
  printf 'export AZURE_NODE_VM_SIZE=%q\n' "$AZURE_NODE_VM_SIZE" >> "$PROMPTS_FILE"
fi
omc::log INFO "Using Azure VM size: $AZURE_NODE_VM_SIZE"

if ! az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az group create --name "$RESOURCE_GROUP" --location "$AZURE_LOCATION" >/dev/null
  omc::log INFO "Created RG: $RESOURCE_GROUP in $AZURE_LOCATION"
else
  existing_rg_loc="$(az group show --name "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null)"
  if [[ "$existing_rg_loc" != "$AZURE_LOCATION" ]]; then
    omc::log ERROR ""
    omc::log ERROR "=== RG LOCATION MISMATCH ==="
    omc::log ERROR "  Existing RG '$RESOURCE_GROUP' is in: $existing_rg_loc"
    omc::log ERROR "  You requested:                       $AZURE_LOCATION"
    omc::log ERROR ""
    omc::log ERROR "Creating AKS in a different region than the RG works in Azure but creates"
    omc::log ERROR "an orphaned MC_* node RG that teardown.sh can't clean up. To resolve:"
    omc::log ERROR "  Option A: change AZURE_LOCATION back to '$existing_rg_loc' in prompts.env"
    omc::log ERROR "  Option B: nuke the stale RG first:"
    omc::log ERROR "    az group delete --name $RESOURCE_GROUP --yes --no-wait"
    omc::log ERROR "    rm -rf $STATE_DIR  # then re-run fresh"
    omc::die "Refusing to proceed with mismatched RG/AKS region"
  fi
  omc::log INFO "RG $RESOURCE_GROUP already exists in $existing_rg_loc"
fi

if ! az aks show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  omc::log INFO "Creating AKS cluster (Ubuntu 24.04, OIDC, Workload Identity)..."
  az aks create \
    --name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$AZURE_LOCATION" \
    --vm-set-type VirtualMachineScaleSets \
    --load-balancer-sku standard \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --os-sku Ubuntu2404 \
    --node-count 3 \
    --node-vm-size "${AZURE_NODE_VM_SIZE}" \
    --generate-ssh-keys >/dev/null
  omc::log INFO "AKS cluster created"
fi

if ! az aks nodepool show --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --name sandbox >/dev/null 2>&1; then
  omc::log INFO "Adding sandbox node pool with daytona-sandbox-c label + taint..."
  az aks nodepool add \
    --cluster-name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --name sandbox \
    --node-count 1 \
    --node-vm-size "${AZURE_NODE_VM_SIZE}" \
    --os-type Linux \
    --os-sku Ubuntu2404 \
    --labels daytona-sandbox-c=true \
    --node-taints "sandbox=true:NoSchedule" >/dev/null
  omc::log INFO "Sandbox node pool added"
fi

# === 4. kubeconfig ===========================================================
omc::log INFO "=== Step 4/10: kubeconfig ==="
az aks get-credentials \
  --name "$CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --overwrite-existing >/dev/null
kubectl config current-context

# === 5. ENFORCE Ubuntu 24.04 on all AKS nodes and the sandbox node pool ======
omc::verify_node_ubuntu "24.04" "" 300
omc::verify_node_ubuntu "24.04" "daytona-sandbox-c=true" 300

# === 6. Namespace ============================================================
omc::log INFO "=== Step 6/10: daytona namespace ==="
kubectl create namespace daytona --dry-run=client -o yaml | kubectl apply -f -

# === 7. ingress-nginx + (optional) cert-manager + (optional) ClusterIssuer ===
omc::log INFO "=== Step 7/10: ingress-nginx + cert provisioning (mode=$TLS_MODE) ==="
omc::ingress_nginx_install
case "$TLS_MODE" in
  cloudflare-dns01)
    omc::cert_manager_install
    omc::cluster_issuer_apply_cf_dns01 "$CLUSTER_ISSUER_EMAIL" "$CLOUDFLARE_API_TOKEN"
    # Start ACME issuance NOW (DNS-01 needs no A records, only the Cloudflare
    # API). If we instead let ingress-shim create the certs at helm-install
    # time, the api's first snapshot push to harbor.<base> races issuance and
    # dies on the nginx fake cert (terminal snapshot state=error).
    omc::certs_preissue "$BASE_DOMAIN" daytona "$CLUSTER_ISSUER"
    ;;
  self-signed)
    omc::log INFO "TLS_MODE=self-signed: skipping cert-manager; chart will genSignedCert at install time"
    ;;
  manual)
    omc::log INFO "TLS_MODE=manual: skipping cert-manager; you must pre-create the TLS Secret"
    omc::log INFO "  Required secrets in namespace daytona BEFORE step 9:"
    omc::log INFO "    ${BASE_DOMAIN}-tls          (covers ${BASE_DOMAIN} + *.${BASE_DOMAIN})"
    omc::confirm "Have you pre-created the TLS Secret in namespace daytona?" \
      || omc::die "Aborted; pre-create the Secrets then re-run."
    ;;
esac

# === 8. Wait for LoadBalancer + DNS records ==================================
omc::log INFO "=== Step 8/10: Wait for LoadBalancer + DNS ==="
LB_TARGET="$(omc::wait_lb_address ingress-nginx ingress-nginx-controller 300)"
omc::log INFO "LoadBalancer target: $LB_TARGET"

cat >&2 <<EOF

==================== DNS RECORDS TO CREATE ====================
The Daytona OSS deployment needs these 2 DNS records pointing at
the ingress LoadBalancer ($LB_TARGET):

  ${BASE_DOMAIN}        A or CNAME   $LB_TARGET     (API + dashboard)
  *.${BASE_DOMAIN}      A or CNAME   $LB_TARGET     (proxy + sandbox subdomains +
                                                      dex.<base> + harbor.<base>)

The wildcard catches dex (auth) and harbor (registry) subdomains as
well as the per-sandbox subdomains under proxy.

Create them in your DNS provider NOW and wait for propagation.
===============================================================

EOF
omc::confirm "Have you created the DNS records above and waited for propagation?" \
  || omc::die "Aborted by operator. Re-run after creating DNS records."

# Certs were pre-issued in step 7; they MUST be Ready before the chart
# installs or the api's first snapshot push hits the ingress fake cert.
if [[ "$TLS_MODE" == "cloudflare-dns01" ]]; then
  omc::certs_wait_ready daytona 20m
fi

# === 9. helm dependency build + helm install =================================
omc::log INFO "=== Step 9/10: helm dependency build + install daytona (OSS) ==="
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo add minio https://charts.min.io >/dev/null 2>&1 || true
helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1 || true
helm repo update >/dev/null

if [[ ! -d "$SCRIPT_DIR/../../charts/daytona/charts" ]] \
    || [[ -z "$(ls -A "$SCRIPT_DIR/../../charts/daytona/charts" 2>/dev/null)" ]]; then
  helm dependency build "$SCRIPT_DIR/../../charts/daytona" >/dev/null
  omc::log INFO "Helm dependencies built (postgres + redis + minio + harbor)"
fi

case "$TLS_MODE" in
  cloudflare-dns01)
    CERT_MANAGER_ANNOTATION='        cert-manager.io/cluster-issuer: "letsencrypt-prod"'
    INGRESS_SELFSIGNED="false"
    HARBOR_CERT_SOURCE="secret"
    ;;
  self-signed)
    CERT_MANAGER_ANNOTATION=""
    INGRESS_SELFSIGNED="true"
    HARBOR_CERT_SOURCE="auto"
    ;;
  manual)
    CERT_MANAGER_ANNOTATION=""
    INGRESS_SELFSIGNED="false"
    HARBOR_CERT_SOURCE="secret"
    ;;
esac
# Self-signed Harbor cert => the runner's dockerd must treat harbor.<base>
# as an insecure registry or snapshot push/pull dies with
# "x509: certificate signed by unknown authority".
if [[ "$TLS_MODE" == "self-signed" ]]; then
  INSECURE_REGISTRIES="[\"harbor.${BASE_DOMAIN}\"]"
else
  INSECURE_REGISTRIES="[]"
fi
export CLUSTER_NAME BASE_DOMAIN CLUSTER_ISSUER RUNNER_IMAGE_TAG \
       POSTGRES_PASSWORD REDIS_PASSWORD MINIO_ROOT_PASSWORD HARBOR_ADMIN_PASSWORD \
       ADMIN_API_KEY ENCRYPTION_KEY ENCRYPTION_SALT \
       CERT_MANAGER_ANNOTATION INGRESS_SELFSIGNED HARBOR_CERT_SOURCE \
       INSECURE_REGISTRIES \
       INTERNAL_REGISTRY_HOST=""
omc::render_template "$SCRIPT_DIR/values-oss.yaml.tmpl" "$VALUES_OUT"

omc::log INFO "Running helm install (this can take 10-15 min for all subcharts to settle)..."
omc::helm_install_wait daytona "$SCRIPT_DIR/../../charts/daytona" daytona "$VALUES_OUT" 20m

# === 10. Summary =============================================================
cat >&2 <<EOF

==================== DAYTONA OSS BRING-UP COMPLETE ====================
API:               https://${BASE_DOMAIN}
Dashboard:         https://${BASE_DOMAIN}  (served by API ingress)
Auth (Dex):        https://dex.${BASE_DOMAIN}
Registry (Harbor): https://harbor.${BASE_DOMAIN}
Sandbox URLs:      https://<sandbox-id>.${BASE_DOMAIN}

Admin credentials (from $SECRETS_FILE):
  Daytona admin API key: \$ADMIN_API_KEY  (use as DAYTONA_API_KEY for SDK/e2e.sh)
  Harbor admin / \$HARBOR_ADMIN_PASSWORD
  Postgres postgres / \$POSTGRES_PASSWORD
  Redis (auth password)
  MinIO minio-admin / \$MINIO_ROOT_PASSWORD

Next steps:
  1. Verify pods: kubectl -n daytona get pods
  2. Check Harbor: open https://harbor.${BASE_DOMAIN} (log in as 'admin')
  3. Daytona dashboard: open https://${BASE_DOMAIN}
  4. Create a sandbox via the dashboard
  5. Run smoke test:  bash $SCRIPT_DIR/e2e.sh
  6. Teardown:        bash $SCRIPT_DIR/teardown.sh

State persisted in: $STATE_DIR
Secrets file:       $SECRETS_FILE (mode 0600 — back up before teardown if needed)
======================================================================
EOF
