#!/usr/bin/env bash
# scripts/aws-setup/up.sh — K8s-native Daytona BYOC bring-up on AWS EKS.
#
# Single interactive entrypoint that:
#   1. prompts for cluster name, base domain, region, credentials
#   2. creates EKS cluster (with OIDC) + node pool with daytona-sandbox-c label + taint
#   3. creates S3 bucket (snapshots + build context)
#   4. creates IAM user + access keys (static mode) OR IAM role (IRSA mode)
#   5. updates kubeconfig
#   6. installs ingress-nginx + cert-manager + Let's Encrypt ClusterIssuer
#   7. waits for LoadBalancer hostname, prints DNS records to create
#   8. waits for operator to confirm DNS propagation
#   9. renders values-region.yaml.tmpl and helm-installs daytona-region
#   10. prints the proxy URL for sandbox-create testing
#
# Idempotent: re-runnable if interrupted. State persists in .state/.
# Operator runs against a real AWS account; this script never executes in CI.
# See /Users/dalinstone/main/test/byoc-overhaul/aws.md for the full test loop.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"
# shellcheck source=../_lib/sku-data.sh
source "$SCRIPT_DIR/../_lib/sku-data.sh"
# shellcheck source=../_lib/sku-aws.sh
source "$SCRIPT_DIR/../_lib/sku-aws.sh"

omc::need_cmd aws eksctl kubectl helm envsubst yq jq

STATE_DIR="$(omc::state_dir "$SCRIPT_DIR")"
PROMPTS_FILE="$STATE_DIR/prompts.env"
VALUES_OUT="$STATE_DIR/values-region.yaml"
CLUSTER_CONFIG="$STATE_DIR/cluster.yaml"
TRUST_POLICY="$STATE_DIR/trust-policy.json"
S3_POLICY="$STATE_DIR/s3-policy.json"

# Re-use prompts from prior partial run, if any.
if [[ -f "$PROMPTS_FILE" ]]; then
  omc::log INFO "Loading saved prompts from $PROMPTS_FILE"
  set -a
  # shellcheck source=/dev/null
  . "$PROMPTS_FILE"
  set +a
else
  unset CLUSTER_NAME BASE_DOMAIN REGION_NAME CLUSTER_ISSUER_EMAIL DAYTONA_API_URL \
        AWS_REGION S3_BUCKET RUNNER_AWS_CREDENTIAL_MODE RUNNER_IMAGE_TAG \
        AWS_NODE_VM_SIZE
fi

# === 1. Interactive prompts ==================================================
omc::log INFO "=== Daytona BYOC: AWS EKS bring-up ==="
omc::prompt CLUSTER_NAME "Cluster name" "daytona-byoc-$(date +%Y%m%d-%H%M%S)"
omc::prompt BASE_DOMAIN  "Public base DNS domain (e.g. byoc.example.com)"
omc::prompt REGION_NAME  "Daytona region name" "${CLUSTER_NAME}"
omc::prompt CLUSTER_ISSUER_EMAIL "Email for Let's Encrypt ClusterIssuer"
omc::prompt DAYTONA_API_URL "Daytona Cloud API URL" "https://api.daytona.io"
omc::prompt_secret DAYTONA_API_KEY "Daytona Cloud admin API key"
omc::prompt AWS_REGION   "AWS region" "us-east-1"
omc::prompt S3_BUCKET    "S3 bucket name (snapshots + build context)" "${CLUSTER_NAME}-snapshots"
omc::prompt RUNNER_AWS_CREDENTIAL_MODE "Runner credential mode (static or irsa)" "static"
omc::prompt RUNNER_IMAGE_TAG "Runner image tag" "v0.183.0"

if [[ "$RUNNER_AWS_CREDENTIAL_MODE" != "static" && "$RUNNER_AWS_CREDENTIAL_MODE" != "irsa" ]]; then
  omc::die "RUNNER_AWS_CREDENTIAL_MODE must be 'static' or 'irsa' (got: $RUNNER_AWS_CREDENTIAL_MODE)"
fi

# Persist prompts so re-runs reuse them.
{
  printf 'export CLUSTER_NAME=%q\n' "$CLUSTER_NAME"
  printf 'export BASE_DOMAIN=%q\n'  "$BASE_DOMAIN"
  printf 'export REGION_NAME=%q\n'  "$REGION_NAME"
  printf 'export CLUSTER_ISSUER_EMAIL=%q\n' "$CLUSTER_ISSUER_EMAIL"
  printf 'export DAYTONA_API_URL=%q\n' "$DAYTONA_API_URL"
  printf 'export AWS_REGION=%q\n'   "$AWS_REGION"
  printf 'export S3_BUCKET=%q\n'    "$S3_BUCKET"
  printf 'export RUNNER_AWS_CREDENTIAL_MODE=%q\n' "$RUNNER_AWS_CREDENTIAL_MODE"
  printf 'export RUNNER_IMAGE_TAG=%q\n' "$RUNNER_IMAGE_TAG"
} > "$PROMPTS_FILE"
chmod 600 "$PROMPTS_FILE"
omc::log INFO "Prompts saved: $PROMPTS_FILE"

# === 1.5 Quota-aware instance type selection ================================
# Sandbox managed node group needs >= 4 vCPU per node within L-1216C47A quota.
if [[ -z "${AWS_NODE_VM_SIZE:-}" ]]; then
  AWS_NODE_VM_SIZE="$(omc::aws_select_instance_type "$AWS_REGION" 4 OMC_INSTANCE_TYPE)"
  printf 'export AWS_NODE_VM_SIZE=%q\n' "$AWS_NODE_VM_SIZE" >> "$PROMPTS_FILE"
fi
omc::log INFO "Using AWS instance type: $AWS_NODE_VM_SIZE"

# === 2. EKS cluster ==========================================================
omc::log INFO "=== Step 2/9: EKS cluster ==="
if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  omc::log INFO "EKS cluster $CLUSTER_NAME already exists in $AWS_REGION"
else
  cat > "$CLUSTER_CONFIG" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "1.30"

iam:
  withOIDC: true

managedNodeGroups:
  - name: sandbox
    desiredCapacity: 1
    minSize: 1
    maxSize: 3
    instanceType: ${AWS_NODE_VM_SIZE}
    amiFamily: Ubuntu2404
    labels:
      daytona-sandbox-c: "true"
    taints:
      - key: sandbox
        value: "true"
        effect: NoSchedule
    volumeSize: 100
EOF
  omc::log INFO "Creating EKS cluster (this takes 15-20 min)..."
  eksctl create cluster -f "$CLUSTER_CONFIG"
fi

# === 3. S3 bucket ============================================================
omc::log INFO "=== Step 3/9: S3 bucket ==="
if aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
  omc::log INFO "S3 bucket $S3_BUCKET already exists"
else
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION"
  else
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION"
  fi
  omc::log INFO "Created S3 bucket: $S3_BUCKET"
fi

# === 4. IAM (static user OR IRSA role) =======================================
omc::log INFO "=== Step 4/9: IAM (mode=$RUNNER_AWS_CREDENTIAL_MODE) ==="

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
S3_POLICY_NAME="${CLUSTER_NAME}-s3"
cat > "$S3_POLICY" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ],
    "Resource": [
      "arn:aws:s3:::${S3_BUCKET}",
      "arn:aws:s3:::${S3_BUCKET}/*"
    ]
  }]
}
EOF

S3_POLICY_ARN=""
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${S3_POLICY_NAME}" >/dev/null 2>&1; then
  S3_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${S3_POLICY_NAME}"
  omc::log INFO "Reusing IAM policy: $S3_POLICY_ARN"
else
  S3_POLICY_ARN="$(aws iam create-policy \
    --policy-name "$S3_POLICY_NAME" \
    --policy-document "file://$S3_POLICY" \
    --query 'Policy.Arn' --output text)"
  omc::log INFO "Created IAM policy: $S3_POLICY_ARN"
fi

IAM_ACCESS_KEY=""
IAM_SECRET_KEY=""
IRSA_ROLE_ARN=""

if [[ "$RUNNER_AWS_CREDENTIAL_MODE" == "static" ]]; then
  IAM_USER="${CLUSTER_NAME}-daytona"
  if ! aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
    aws iam create-user --user-name "$IAM_USER" >/dev/null
    omc::log INFO "Created IAM user: $IAM_USER"
  fi
  aws iam attach-user-policy --user-name "$IAM_USER" --policy-arn "$S3_POLICY_ARN" 2>/dev/null || true

  IAM_KEYS_FILE="$STATE_DIR/iam-keys.env"
  if [[ -f "$IAM_KEYS_FILE" ]]; then
    # shellcheck source=/dev/null
    . "$IAM_KEYS_FILE"
    omc::log INFO "Reusing IAM access keys from $IAM_KEYS_FILE"
  else
    KEY_JSON="$(aws iam create-access-key --user-name "$IAM_USER")"
    IAM_ACCESS_KEY="$(echo "$KEY_JSON" | jq -r .AccessKey.AccessKeyId)"
    IAM_SECRET_KEY="$(echo "$KEY_JSON" | jq -r .AccessKey.SecretAccessKey)"
    {
      printf 'export IAM_ACCESS_KEY=%q\n' "$IAM_ACCESS_KEY"
      printf 'export IAM_SECRET_KEY=%q\n' "$IAM_SECRET_KEY"
    } > "$IAM_KEYS_FILE"
    chmod 600 "$IAM_KEYS_FILE"
    omc::log INFO "Created IAM access keys (saved to $IAM_KEYS_FILE, 0600)"
  fi
else
  # IRSA mode: trust policy bound to cluster OIDC + runner SA.
  OIDC_HOST="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||')"
  RUNNER_SA="${CLUSTER_NAME}-daytona-region-runner"
  IRSA_ROLE_NAME="${CLUSTER_NAME}-runner-irsa"
  cat > "$TRUST_POLICY" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_HOST}:aud": "sts.amazonaws.com",
        "${OIDC_HOST}:sub": "system:serviceaccount:daytona:${RUNNER_SA}"
      }
    }
  }]
}
EOF
  if aws iam get-role --role-name "$IRSA_ROLE_NAME" >/dev/null 2>&1; then
    IRSA_ROLE_ARN="$(aws iam get-role --role-name "$IRSA_ROLE_NAME" --query 'Role.Arn' --output text)"
    omc::log INFO "Reusing IRSA role: $IRSA_ROLE_ARN"
  else
    IRSA_ROLE_ARN="$(aws iam create-role \
      --role-name "$IRSA_ROLE_NAME" \
      --assume-role-policy-document "file://$TRUST_POLICY" \
      --query 'Role.Arn' --output text)"
    omc::log INFO "Created IRSA role: $IRSA_ROLE_ARN"
  fi
  aws iam attach-role-policy --role-name "$IRSA_ROLE_NAME" --policy-arn "$S3_POLICY_ARN" 2>/dev/null || true
  omc::log WARN "IRSA mode: upstream runner currently hard-requires non-empty AWS_ACCESS_KEY_ID/SECRET."
  omc::log WARN "See docs/upstream-issues/runner-irsa-support.md. For working v1 tests, use --static."
fi

# === 5. kubeconfig ===========================================================
omc::log INFO "=== Step 5/9: kubeconfig ==="
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
kubectl config current-context

# === 5b. ENFORCE Ubuntu 24.04 on the sandbox node pool ======================
# The Daytona helm chart docker-installer targets Ubuntu 24.04 (noble) .deb
# packages directly. NO EXCEPTIONS — fail-fast if anything else.
omc::verify_node_ubuntu "24.04" "daytona-sandbox-c=true" 300

# === 6. Namespace ============================================================
omc::log INFO "=== Step 6/9: daytona namespace ==="
kubectl create namespace daytona --dry-run=client -o yaml | kubectl apply -f -

# === 7. ingress-nginx + cert-manager + ClusterIssuer =========================
omc::log INFO "=== Step 7/9: ingress-nginx + cert-manager ==="
omc::ingress_nginx_install
omc::cert_manager_install
omc::cluster_issuer_apply "$CLUSTER_ISSUER_EMAIL"

# === 8. Wait for LoadBalancer + DNS records ==================================
omc::log INFO "=== Step 8/9: Wait for LoadBalancer + DNS ==="
LB_TARGET="$(omc::wait_lb_address ingress-nginx ingress-nginx-controller 300)"
omc::log INFO "LoadBalancer target: $LB_TARGET"
omc::print_dns_records "$BASE_DOMAIN" "$LB_TARGET"
omc::confirm "Have you created the DNS records above and waited for propagation?" \
  || omc::die "Aborted by operator. Re-run after creating DNS records."

# === 9. Render values + helm install =========================================
omc::log INFO "=== Step 9/9: helm install daytona-region ==="
export CLUSTER_NAME BASE_DOMAIN REGION_NAME DAYTONA_API_URL DAYTONA_API_KEY \
       AWS_REGION S3_BUCKET RUNNER_AWS_CREDENTIAL_MODE RUNNER_IMAGE_TAG \
       IAM_ACCESS_KEY IAM_SECRET_KEY IRSA_ROLE_ARN INTERNAL_REGISTRY_HOST=""
omc::render_template "$SCRIPT_DIR/values-region.yaml.tmpl" "$VALUES_OUT"
omc::helm_install_wait daytona-region "$SCRIPT_DIR/../../charts/daytona-region" daytona "$VALUES_OUT"

# === Summary =================================================================
cat >&2 <<EOF

==================== BRING-UP COMPLETE ====================
Proxy URL:         https://proxy.${BASE_DOMAIN}
Snapshot manager:  https://snapshots.${BASE_DOMAIN}

Next steps:
  1. Open the Daytona Cloud dashboard for ${REGION_NAME}
  2. Verify the runner is registered: kubectl -n daytona get pods
  3. Create a sandbox via the web UI to validate end-to-end
  4. Run the SDK smoke test:    bash $SCRIPT_DIR/e2e.sh
  5. Teardown when done:         bash $SCRIPT_DIR/teardown.sh

State persisted in: $STATE_DIR
===========================================================
EOF
