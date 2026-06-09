#!/usr/bin/env bash
# scripts/_lib/common.sh — shared helpers for BYOC e2e setup scripts.
# Sourced by scripts/{aws,azure,gcs}-setup/up.sh and teardown.sh.
#
# Conventions:
#   * Functions are namespaced with omc:: prefix to avoid collisions.
#   * All functions assume `set -euo pipefail` is set in the caller; do NOT
#     re-enable it here (lets the caller decide).
#   * Logging goes to STDERR so stdout can carry structured data (URLs, paths).
#   * Honor OMC_NONINTERACTIVE=1 (use defaults or fail) and OMC_YES=1 (skip
#     confirmation prompts).

# ---------------------------------------------------------------- logging
omc::log() {
  local level="$1"; shift
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$*" >&2
}

omc::die() {
  omc::log ERROR "$*"
  exit 1
}

# ---------------------------------------------------------------- prereqs
omc::need_cmd() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    omc::die "Missing required commands: ${missing[*]}. Install them before running this script."
  fi
}

# ---------------------------------------------------------------- prompts
# omc::prompt_choice VAR "label" CHOICE1 [CHOICE2 ...]
# Prompts the operator to pick one of the listed choices by number. First choice
# is the default. Pre-set values (e.g. TLS_MODE=cloudflare-dns01 in env) are
# honored if they match one of the choices; otherwise the prompt rejects and
# re-asks. In OMC_NONINTERACTIVE mode, uses the first choice as default.
omc::prompt_choice() {
  local var="$1" label="$2"; shift 2
  local choices=("$@")
  local default="${choices[0]}"
  if [[ -n "${!var:-}" ]]; then
    local found=0
    for c in "${choices[@]}"; do
      if [[ "$c" == "${!var}" ]]; then found=1; break; fi
    done
    if [[ "$found" -eq 1 ]]; then
      omc::log INFO "$var (pre-set): ${!var}"
      return 0
    fi
    omc::log WARN "$var pre-set to '${!var}' but not in allowed choices (${choices[*]}); re-prompting"
  fi
  if [[ "${OMC_NONINTERACTIVE:-0}" == "1" ]]; then
    printf -v "$var" '%s' "$default"
    export "${var?}"
    omc::log INFO "$var (default, non-interactive): $default"
    return 0
  fi
  echo "$label" >&2
  local i=1
  for c in "${choices[@]}"; do
    echo "  $i) $c" >&2
    i=$((i+1))
  done
  local reply
  while true; do
    read -r -p "Choose 1-${#choices[@]} [1=$default]: " reply
    reply="${reply:-1}"
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#choices[@]} )); then
      printf -v "$var" '%s' "${choices[$((reply-1))]}"
      export "${var?}"
      omc::log INFO "$var = ${!var}"
      return 0
    fi
    echo "  Invalid choice; pick a number 1-${#choices[@]}" >&2
  done
}

# omc::prompt VAR "label" [default]
# Reads a value into VAR. If OMC_NONINTERACTIVE=1, uses default or dies.
omc::prompt() {
  local var="$1" label="$2" default="${3:-}"
  if [[ -n "${!var:-}" ]]; then
    omc::log INFO "$var (pre-set): ${!var}"
    return 0
  fi
  if [[ "${OMC_NONINTERACTIVE:-0}" == "1" ]]; then
    if [[ -n "$default" ]]; then
      printf -v "$var" '%s' "$default"
      export "${var?}"
      omc::log INFO "$var (default, non-interactive): $default"
      return 0
    fi
    omc::die "$var has no value and no default; cannot prompt in non-interactive mode."
  fi
  local value
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$label: " value
    while [[ -z "$value" ]]; do
      omc::log WARN "$var cannot be empty"
      read -r -p "$label: " value
    done
  fi
  printf -v "$var" '%s' "$value"
  export "${var?}"
}

# omc::prompt_secret VAR "label" — no echo, no default.
omc::prompt_secret() {
  local var="$1" label="$2"
  if [[ -n "${!var:-}" ]]; then
    omc::log INFO "$var (pre-set, masked)"
    return 0
  fi
  if [[ "${OMC_NONINTERACTIVE:-0}" == "1" ]]; then
    omc::die "$var is a secret and has no value; cannot prompt in non-interactive mode."
  fi
  local value
  read -r -s -p "$label: " value
  printf '\n' >&2
  if [[ -z "$value" ]]; then
    omc::die "$var cannot be empty"
  fi
  printf -v "$var" '%s' "$value"
  export "${var?}"
}

# omc::confirm "label" — y/N (default N). OMC_YES=1 auto-yes.
omc::confirm() {
  local label="$1"
  if [[ "${OMC_YES:-0}" == "1" ]]; then
    omc::log INFO "AUTO-YES: $label"
    return 0
  fi
  if [[ "${OMC_NONINTERACTIVE:-0}" == "1" ]]; then
    omc::die "Confirmation prompt blocked in non-interactive mode: $label"
  fi
  local reply
  read -r -p "$label (y/N): " reply
  if [[ "$reply" =~ ^[Yy] ]]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------- templating
# omc::render_template src.tmpl dst.yaml
# envsubst wrapper that fails on UNRESOLVED ${...} placeholders.
# Rendered output is chmod'd 0600 because it embeds secrets (DAYTONA_API_KEY,
# IAM_SECRET_KEY, HMAC_SECRET_KEY, RCLONE_SECRET_KEY) lifted from the
# matching .state/*.env files.
omc::render_template() {
  local src="$1" dst="$2"
  if [[ ! -f "$src" ]]; then
    omc::die "render_template: source missing: $src"
  fi
  envsubst < "$src" > "$dst"
  chmod 600 "$dst"
  local unresolved
  unresolved="$(grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$dst" || true)"
  if [[ -n "$unresolved" ]]; then
    omc::log ERROR "render_template: unresolved placeholders in $dst:"
    printf '%s\n' "$unresolved" >&2
    omc::die "set the missing vars before re-running"
  fi
  omc::log INFO "rendered $src -> $dst ($(wc -l < "$dst") lines, mode 0600)"
}

# ---------------------------------------------------------------- state
# omc::state_dir SCRIPT_DIR — returns "$SCRIPT_DIR/.state", mkdir -p.
omc::state_dir() {
  local script_dir="$1"
  local dir="$script_dir/.state"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# ---------------------------------------------------------------- kube helpers
# omc::wait_lb_address NS SVC [timeout_sec=300]
# Polls the Service's LoadBalancer ingress[0].ip OR hostname, prints whichever non-empty.
omc::wait_lb_address() {
  local ns="$1" svc="$2" timeout="${3:-300}"
  omc::log INFO "Waiting up to ${timeout}s for LoadBalancer address on $ns/$svc..."
  local elapsed=0 sleep_sec=5
  local ip hostname
  while [[ $elapsed -lt $timeout ]]; do
    ip="$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    hostname="$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      printf '%s' "$ip"
      return 0
    fi
    if [[ -n "$hostname" ]]; then
      printf '%s' "$hostname"
      return 0
    fi
    sleep $sleep_sec
    elapsed=$((elapsed + sleep_sec))
  done
  omc::die "Timed out waiting for LoadBalancer address on $ns/$svc"
}

# omc::print_dns_records BASE_DOMAIN LB_TARGET
# Prints the 3 DNS records the operator must create.
omc::print_dns_records() {
  local base="$1" target="$2"
  local rec_type="A"
  if [[ "$target" == *.* && ! "$target" =~ ^[0-9.]+$ ]]; then
    rec_type="CNAME"
  fi
  cat >&2 <<EOF

==================== DNS RECORDS TO CREATE ====================
The Daytona BYOC region needs these DNS records pointing at the
ingress LoadBalancer ($target):

  proxy.${base}        $rec_type   $target
  *.proxy.${base}      $rec_type   $target     (wildcard for sandbox subdomains)
  snapshots.${base}    $rec_type   $target

Create them in your DNS provider (Route53/Azure DNS/Cloud DNS/...) NOW.
Wait for propagation (usually 30-300s) before continuing.
===============================================================

EOF
}

# ---------------------------------------------------------------- helm helpers
# omc::ingress_nginx_install [namespace=ingress-nginx]
# Critical: pass TCP probe annotations on the LB Service. Azure Standard LB defaults
# its health probe to HTTP / against the NodePort. ingress-nginx returns 404 for /,
# Standard LB treats !=200 as unhealthy, marks ALL backends down, and SILENTLY drops
# inbound packets at the network layer (real SYN timeout, not HTTP error). TCP probes
# bypass the HTTP semantic entirely and validate the port is open. See:
# https://kubernetes.io/docs/concepts/services-networking/cloud-providers/#load-balancer
omc::ingress_nginx_install() {
  local ns="${1:-ingress-nginx}"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    -n "$ns" --create-namespace \
    --set-string "controller.service.annotations.service\.beta\.kubernetes\.io/port_80_health-probe_protocol=tcp" \
    --set-string "controller.service.annotations.service\.beta\.kubernetes\.io/port_443_health-probe_protocol=tcp" \
    --wait --timeout 5m \
    || omc::die "ingress-nginx install failed"
  omc::log INFO "ingress-nginx ready in $ns (TCP probes on 80/443)"
}

# omc::cert_manager_install [namespace=cert-manager]
omc::cert_manager_install() {
  local ns="${1:-cert-manager}"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    -n "$ns" --create-namespace \
    --set crds.enabled=true \
    --wait --timeout 5m \
    || omc::die "cert-manager install failed"
  omc::log INFO "cert-manager ready in $ns"
}

# omc::cluster_issuer_apply EMAIL
# Applies a Let's Encrypt HTTP-01 ClusterIssuer named letsencrypt-prod.
# Wave 3 placeholder; filled in W3.1.
omc::cluster_issuer_apply() {
  local email="$1"
  if [[ -z "$email" ]]; then
    omc::die "cluster_issuer_apply: email is required"
  fi
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: ${email}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
  omc::log INFO "ClusterIssuer letsencrypt-prod applied (email=${email})"
}

# omc::cluster_issuer_apply_cf_dns01 EMAIL CF_API_TOKEN [ns=cert-manager]
# Applies a Let's Encrypt DNS-01 ClusterIssuer named letsencrypt-prod with a
# Cloudflare solver. REQUIRED for wildcard SANs — HTTP-01 cannot satisfy
# wildcard challenges per Let's Encrypt rules. The daytona chart's api/proxy
# ingresses emit wildcard TLS specs (*.<baseDomain>), so DNS-01 is the only
# challenge type that yields valid certs for those ingresses.
#
# CF_API_TOKEN must have these zone-scoped permissions for BASE_DOMAIN's zone:
#   Zone:Read, Zone DNS:Edit
# Create at: Cloudflare dashboard → My Profile → API Tokens → Create Token →
# "Edit zone DNS" template.
omc::cluster_issuer_apply_cf_dns01() {
  local email="$1" cf_token="$2" ns="${3:-cert-manager}"
  if [[ -z "$email" || -z "$cf_token" ]]; then
    omc::die "cluster_issuer_apply_cf_dns01: email and cf_token are required"
  fi

  kubectl -n "$ns" create secret generic cloudflare-api-token \
    --from-literal=api-token="$cf_token" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: ${email}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
EOF
  omc::log INFO "ClusterIssuer letsencrypt-prod applied (DNS-01 via Cloudflare; email=${email})"
}

# omc::az_register_providers PROVIDER1 PROVIDER2 ...
# Checks each Azure resource provider's registrationState; for any not "Registered",
# prompts to register (with --wait). NEW Azure subscriptions ship with no providers
# registered, so `az aks create` fails with MissingSubscriptionRegistration. This
# is a one-time-per-subscription setup; subsequent up.sh re-runs are no-ops.
omc::az_register_providers() {
  local missing=()
  local ns state
  for ns in "$@"; do
    state="$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || true)"
    if [[ "$state" != "Registered" ]]; then
      omc::log INFO "Azure provider $ns: ${state:-Unknown} (needs registration)"
      missing+=("$ns")
    else
      omc::log INFO "Azure provider $ns: Registered"
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  omc::log WARN ""
  omc::log WARN "Azure subscription needs ${#missing[@]} resource provider(s) registered:"
  omc::log WARN "  ${missing[*]}"
  omc::log WARN "Registration takes 2-5 min per provider and is a one-time per-subscription setup."
  omc::log WARN ""
  if ! omc::confirm "Register the missing providers now? (No = abort + run manually)"; then
    omc::log ERROR "Aborted. Run manually before re-running this script:"
    local p
    for p in "${missing[@]}"; do
      omc::log ERROR "  az provider register --namespace $p --wait"
    done
    omc::die "Provider registration required."
  fi

  for ns in "${missing[@]}"; do
    omc::log INFO "Registering $ns (may take 2-5 min)..."
    az provider register --namespace "$ns" --wait
    omc::log INFO "$ns Registered"
  done
}

# omc::verify_node_ubuntu [required_version=24.04] [label_selector=daytona-sandbox-c=true] [timeout=300]
# Fails-fast if any node matching the selector is NOT running the required Ubuntu version.
# The Daytona helm chart's docker-installer downloads Ubuntu 24.04 (noble) .deb
# packages directly — running on Ubuntu 22.04 (jammy) or any other distro WILL
# fail when the runner attempts to bootstrap Docker on the node.
# This function is the gatekeeper that catches this BEFORE helm install starts,
# so the operator sees a clear error instead of a cryptic docker-installer crash.
# NO EXCEPTIONS — operator override is intentionally not provided.
omc::verify_node_ubuntu() {
  local required_version="${1:-24.04}"
  local label_selector="${2:-daytona-sandbox-c=true}"
  local timeout="${3:-300}"

  omc::log INFO "Verifying nodes are running Ubuntu $required_version (selector: $label_selector)..."

  local elapsed=0 node_count=0
  while [[ $elapsed -lt $timeout ]]; do
    node_count="$(kubectl get nodes -l "$label_selector" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')"
    if [[ "$node_count" -gt 0 ]]; then
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [[ "$node_count" -eq 0 ]]; then
    omc::die "verify_node_ubuntu: no nodes match selector '$label_selector' after ${timeout}s"
  fi

  local nodes_os
  nodes_os="$(kubectl get nodes -l "$label_selector" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.osImage}{"\n"}{end}')"

  local bad_nodes="" good_count=0
  while IFS=$'\t' read -r name osimage; do
    [[ -z "$name" ]] && continue
    if [[ "$osimage" == *"Ubuntu $required_version"* ]]; then
      good_count=$((good_count + 1))
      omc::log INFO "  $name -> $osimage [OK]"
    else
      bad_nodes+="  $name -> $osimage"$'\n'
    fi
  done <<< "$nodes_os"

  if [[ -n "$bad_nodes" ]]; then
    omc::log ERROR ""
    omc::log ERROR "==================== UBUNTU VERSION MISMATCH ===================="
    omc::log ERROR "The following nodes are NOT running Ubuntu $required_version:"
    printf '%s' "$bad_nodes" >&2
    omc::log ERROR ""
    omc::log ERROR "The Daytona helm chart's docker-installer downloads Ubuntu 24.04"
    omc::log ERROR "(noble) .deb packages directly. Running on any other Ubuntu version"
    omc::log ERROR "WILL fail when the runner tries to bootstrap Docker."
    omc::log ERROR ""
    omc::log ERROR "Options:"
    omc::log ERROR "  1. Run teardown.sh, then re-run up.sh (it requests Ubuntu 24.04 explicitly)"
    omc::log ERROR "  2. Try a different cloud region where Ubuntu 24.04 is GA"
    omc::log ERROR "  3. Upgrade your cloud CLI (eksctl/az/gcloud) to a version supporting Ubuntu 24.04"
    omc::log ERROR "================================================================="
    omc::die "Refusing to continue. Ubuntu 24.04 is REQUIRED with NO EXCEPTIONS."
  fi

  omc::log INFO "All $good_count node(s) verified running Ubuntu $required_version"
}

# omc::helm_install_wait RELEASE CHART_PATH NS VALUES_FILE [timeout=10m]
omc::helm_install_wait() {
  local release="$1" chart="$2" ns="$3" values="$4" timeout="${5:-10m}"
  helm upgrade --install "$release" "$chart" \
    -n "$ns" --create-namespace \
    -f "$values" \
    --wait --timeout "$timeout" \
    || omc::die "helm install of $release failed"
  omc::log INFO "$release deployed in $ns"
}

# ---------------------------------------------------------------- cache
# omc::cache_fresh PATH [ttl_min=15] -> 0 if file exists and is younger than ttl_min minutes.
# BSD/GNU portable via `find -mmin`. macOS bash 3.2 compatible.
omc::cache_fresh() {
  local path="$1" ttl="${2:-15}"
  [[ -f "$path" ]] || return 1
  local fresh
  fresh="$(find "$path" -mmin -"$ttl" -print 2>/dev/null | head -n 1)"
  [[ -n "$fresh" ]]
}

# ---------------------------------------------------------------- menu picker
# omc::pick_from_menu LABEL CHOICES_TSV [override_var]
#
# CHOICES_TSV: newline-separated TSV rows. First row is the header (rendered
# without an index). Subsequent rows are choices; the first column is the
# canonical NAME returned on STDOUT.
#
# Honors:
#   * OMC_NONINTERACTIVE=1   -> pick row 1 silently
#   * ${override_var}        -> skip menu entirely; must match a NAME in body
#                              unless OMC_INSTANCE_TYPE_FORCE=1 (logs WARN)
#
# Output contract:
#   * Menu + log lines    -> STDERR (so callers can capture STDOUT)
#   * Chosen NAME only    -> STDOUT (so `X=$(omc::pick_from_menu ...)` works)
omc::pick_from_menu() {
  local label="$1" tsv="$2" override_var="${3:-}"
  local override=""
  if [[ -n "$override_var" && -n "${!override_var:-}" ]]; then
    override="${!override_var}"
  fi
  local header body count
  header="$(printf '%s\n' "$tsv" | head -n 1)"
  body="$(printf '%s\n' "$tsv" | tail -n +2)"
  count="$(printf '%s\n' "$body" | grep -c . || true)"
  if [[ "$count" -eq 0 ]]; then
    omc::die "pick_from_menu: no viable choices for '$label'"
  fi
  # Render menu to STDERR
  {
    printf '\n%s\n\n' "$label"
    printf '  #  '
    printf '%s\n' "$header" | awk -F'\t' '{for(i=1;i<=NF;i++) printf "%-20s", $i; print ""}'
    local i=1 line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf '  %d  ' "$i"
      printf '%s\n' "$line" | awk -F'\t' '{for(i=1;i<=NF;i++) printf "%-20s", $i; print ""}'
      i=$((i + 1))
    done <<< "$body"
    printf '\n'
  } >&2
  # Override path (skip interactive)
  if [[ -n "$override" ]]; then
    local found=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$(printf '%s' "$line" | awk -F'\t' '{print $1}')" == "$override" ]]; then
        found="$override"
        break
      fi
    done <<< "$body"
    if [[ -z "$found" ]]; then
      if [[ "${OMC_INSTANCE_TYPE_FORCE:-0}" == "1" ]]; then
        omc::log WARN "Override $override_var=$override not in viable list, forcing anyway (OMC_INSTANCE_TYPE_FORCE=1)"
        printf '%s' "$override"
        return 0
      fi
      omc::die "Override $override_var=$override is NOT in the viable list above. Pick a value from the menu, or set OMC_INSTANCE_TYPE_FORCE=1 to bypass."
    fi
    omc::log INFO "Using $override_var=$override (skipping interactive menu)"
    printf '%s' "$override"
    return 0
  fi
  # Non-interactive: pick row 1
  if [[ "${OMC_NONINTERACTIVE:-0}" == "1" ]]; then
    local first
    first="$(printf '%s\n' "$body" | head -n 1 | awk -F'\t' '{print $1}')"
    omc::log INFO "Non-interactive default: $first"
    printf '%s' "$first"
    return 0
  fi
  # Interactive pick
  local pick=""
  while :; do
    read -r -p "Pick [1-$count, default 1]: " pick
    pick="${pick:-1}"
    if [[ "$pick" =~ ^[0-9]+$ ]] && [[ "$pick" -ge 1 ]] && [[ "$pick" -le "$count" ]]; then
      break
    fi
    omc::log WARN "Invalid; enter a number between 1 and $count."
  done
  local chosen
  chosen="$(printf '%s\n' "$body" | awk -v n="$pick" -F'\t' 'NR==n {print $1; exit}')"
  omc::log INFO "Selected: $chosen"
  printf '%s' "$chosen"
}
