# Daytona BYOC test — GCP / GKE Standard

Single interactive script that creates a GKE **Standard** cluster (NOT Autopilot), a GCS bucket with HMAC keys for S3-interop, and deploys the daytona-region helm chart.

## Prerequisites

| Tool | Check |
|---|---|
| `gcloud` 568+ | `gcloud --version` |
| `kubectl`, `helm`, `envsubst`, `yq`, `jq` | see [`README.md`](README.md) |

GCP project:

```bash
gcloud auth login
gcloud auth application-default login    # ADC for storage HMAC create
gcloud config set project <your-project>
gcloud projects describe <your-project>  # confirm
```

Required roles on the project: `roles/container.admin`, `roles/storage.admin`, `roles/iam.serviceAccountAdmin`, `roles/artifactregistry.admin` (if you opt into AR later).

## Run

```bash
cd ~/main/fork/helm-charts
bash scripts/gcs-setup/up.sh
```

Prompts:

| Prompt | Default | Notes |
|---|---|---|
| Cluster name | `daytona-byoc-<timestamp>` | |
| Public base DNS domain | — | |
| Daytona region name | `<cluster>` | |
| Email for Let's Encrypt | — | |
| Daytona Cloud API URL | `https://api.daytona.io` | |
| Daytona Cloud admin API key | — | **secret** |
| GCP project ID | — | no default; must prompt |
| GCP region | `us-central1` | |
| GCS bucket name | `<cluster>-snapshots` | Globally unique |
| Runner image tag | `v0.183.0` | Default matches chart appVersion |

## What the script does

1. **GKE Standard cluster** — explicitly NOT Autopilot. Autopilot blocks privileged DaemonSets, and the Daytona runner uses sysbox + `nsenter` into host PID 1 → it MUST be privileged. Created with `--workload-pool=<project>.svc.id.goog` (Workload Identity ready for Prompt 2) + `--image-type=UBUNTU_CONTAINERD` (GKE stable channel defaults this to **Ubuntu 24.04** for K8s 1.31+). ~5-10 min. After node pool join, an `omc::verify_node_ubuntu "24.04"` gate refuses to continue if nodes aren't on Ubuntu 24.04 — no exceptions.
2. **Sandbox node pool** `daytona-sandbox` with `daytona-sandbox-c=true` label + `sandbox=true:NoSchedule` taint, on Ubuntu containerd nodes.
3. **GCS bucket** + **GSA** (`daytona-byoc-<cluster>@<project>.iam.gserviceaccount.com`) + `roles/storage.objectAdmin` binding on the bucket.
4. **HMAC keys** for the GSA via `gcloud storage hmac create`. The accessId + secret are S3-compatible credentials. Saved 0600 to `.state/hmac.env`.
5. **kubeconfig** via `gcloud container clusters get-credentials`.
6. **daytona namespace** + **PSA privileged label** (`pod-security.kubernetes.io/enforce=privileged`). GKE 1.25+ enforces Pod Security Admission by default; this label is required for the privileged runner DaemonSet.
7. **ingress-nginx** + **cert-manager** + Let's Encrypt ClusterIssuer.
8. **LoadBalancer wait** for the GCP regional LB IP.
9. **DNS records** printed.
10. **`helm install daytona-region`** with `https://storage.googleapis.com` as the S3 endpoint.

## Verify

```bash
kubectl -n daytona get pods

# PSA label applied?
kubectl get namespace daytona -o yaml | grep pod-security

# HMAC keys reaching runner env?
kubectl -n daytona exec daemonset/daytona-region-runner -c runner -- env | \
  grep -E 'AWS_ENDPOINT_URL|AWS_DEFAULT_BUCKET|AWS_ACCESS_KEY_ID'

# Snapshot-manager talking to GCS interop?
kubectl -n daytona logs deployment/daytona-region-snapshot-manager --tail=30
```

You should see `AWS_ENDPOINT_URL=https://storage.googleapis.com` and a `GOOG...` access key ID. The snapshot-manager will log GCS interop API calls.

## Smoke test

Same as AWS — open <https://app.daytona.io/dashboard/sandboxes>, create a sandbox in your BYOC region, expect `Ready` within ~60s.

Programmatic:

```bash
export DAYTONA_API_URL=https://api.daytona.io
export DAYTONA_API_KEY=<your-key>
export REGION_NAME=<region-name>
bash scripts/gcs-setup/e2e.sh
```

## Teardown

```bash
bash scripts/gcs-setup/teardown.sh
```

1. Helm uninstalls daytona-region
2. Deletes daytona namespace
3. Deactivates + deletes HMAC keys
4. Removes IAM binding + deletes GSA
5. Recursively deletes GCS bucket
6. Deletes GKE cluster (~5-10 min)
7. Cleans up `.state/` and kubeconfig contexts

Confirm with `gcloud container clusters describe <name> --region <region>` → `NOT_FOUND`.

## Known gaps (Prompt 1)

- **GKE Workload Identity for the runner pod** is Prompt 2. Until then, HMAC keys are the S3-compat path (worked just like AWS IRSA static keys).
- **Artifact Registry (AR)** is NOT created by `up.sh` — the legacy `scripts/gcs-setup/.legacy/gcr-setup.sh` handles AR for the operator's own snapshot images, but it's optional. The daytona-runner does NOT pull from operator-owned registries; the Daytona control plane brokers private registry auth centrally.
- **Wildcard DNS** is not issued (HTTP-01 limitations). See [`troubleshooting.md`](troubleshooting.md) for the DNS-01 upgrade path.

## State files

| File | Mode | Purpose |
|---|---|---|
| `scripts/gcs-setup/.state/prompts.env` | 600 | Prompt answers |
| `scripts/gcs-setup/.state/hmac.env` | 600 | GCS HMAC access ID + secret |
| `scripts/gcs-setup/.state/values-region.yaml` | 600 | Rendered helm values (contains HMAC secret + Daytona API key) |

`hmac.env` is your full storage credential — guard like a secret.

## Why GKE Standard, not Autopilot?

GKE Autopilot is the simpler managed path, but it explicitly blocks privileged Pods and requires every workload to fit a narrow allowlist. The Daytona runner DaemonSet:

- runs as `securityContext.privileged: true`
- uses `hostPID: true` and `hostNetwork: true`
- mounts `hostPath: /` for the `nsenter -t 1` host-namespace escape
- runs sysbox-runc to launch sandbox containers with privileged-like semantics under the hood

These are all incompatible with Autopilot's threat model. Use Standard.
