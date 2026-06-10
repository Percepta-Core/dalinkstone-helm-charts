# Daytona BYOC Overhaul — Test Loop

End-to-end testing for the K8s-native Daytona BYOC foundation (Prompt 1 of 3) on AWS / Azure / GCP. Each cloud has a single interactive bring-up script that creates a real cluster + storage + identity, deploys the daytona-region helm chart, and gives you a proxy URL where you can create a sandbox to validate the deployment works.

Prompt 1 lives on the `ulw/p1-foundation` branch of [`helm-charts`](https://github.com/dalinkstone/helm-charts). Before running any of these scripts, the operator should already have that branch checked out at `~/main/fork/helm-charts`.

## The test loop (every cloud)

```
┌────────────────────────────────────────────────────────────────┐
│ 1. cd ~/main/fork/helm-charts                                  │
│ 2. bash scripts/<aws|azure|gcs>-setup/up.sh                    │
│    (interactive prompts → cluster + storage + helm install)    │
│ 3. Copy the printed DNS records into your DNS provider         │
│ 4. Press y when DNS has propagated                             │
│ 5. Open https://app.daytona.io and find your region            │
│ 6. Create a sandbox via the web UI                             │
│ 7. (optional) bash scripts/<cloud>-setup/e2e.sh (SDK smoke)    │
│ 8. bash scripts/<cloud>-setup/teardown.sh when done            │
└────────────────────────────────────────────────────────────────┘
```

Total wall-clock for the happy path: ~30 minutes per cloud (cluster create dominates).

## Common prerequisites

| Tool | Version | Install |
|---|---|---|
| `kubectl` | any recent | `brew install kubectl` |
| `helm` | 3.14+ | `brew install helm` |
| `envsubst` | gettext | `brew install gettext` |
| `yq` | 4.x | `brew install yq` |
| `jq` | 1.6+ | `brew install jq` |
| `shellcheck` | any | `brew install shellcheck` (CI only) |

Per cloud:

| Cloud | Tool | Authentication |
|---|---|---|
| AWS | `aws` v2.34+, `eksctl` | `aws configure` (or SSO) — confirm with `aws sts get-caller-identity` |
| Azure | `az` | `az login` — confirm with `az account show` |
| GCP | `gcloud` 568+ | `gcloud auth login && gcloud auth application-default login` |

You also need:

- A **base DNS domain** you can create A/CNAME records on (e.g. `byoc.example.com`). The scripts derive `proxy.<base>`, `*.proxy.<base>`, and `snapshots.<base>` from this. Wildcard support required for sandbox subdomains.
- A **Daytona Cloud admin API key** from <https://app.daytona.io/dashboard/keys>.
- An **email address** for Let's Encrypt account registration (any address you receive mail at).

## Hard requirement: Ubuntu 24.04 nodes (NO EXCEPTIONS)

The Daytona helm chart's docker-installer downloads Ubuntu 24.04 (noble) `.deb` packages directly. Running on any other Ubuntu version will fail when the runner tries to bootstrap Docker on the node. Each `up.sh` script:

1. Explicitly requests Ubuntu 24.04 from the cloud (`amiFamily: Ubuntu2404` on EKS, `--os-sku Ubuntu2404` on AKS, `--image-type=UBUNTU_CONTAINERD` with GKE stable channel for GKE 1.31+).
2. After cluster + node pool join, calls `omc::verify_node_ubuntu "24.04"` which polls `status.nodeInfo.osImage` and **refuses to continue** if any required node is on a different Ubuntu version. Azure checks every AKS node, then checks the sandbox selector again.

There is no operator override flag. If the verify gate fails, either: (a) tear down and re-run (which requests Ubuntu 24.04 explicitly), (b) try a different cloud region where Ubuntu 24.04 is GA, or (c) upgrade your cloud CLI to one that supports Ubuntu 24.04.

## Two deployment shapes

### Shape 1: BYOC region (compute-only; control plane in Daytona Cloud)

You bring the compute (AKS/EKS/GKE), Daytona Cloud manages the control plane. Minimal infra in your account: cluster + S3-compat storage + runner DaemonSet. Each cloud has its own setup dir.

- [`aws.md`](aws.md) — EKS + S3 + IAM + IRSA (uses `charts/daytona-region/`)
- [`azure.md`](azure.md) — AKS + Azure Blob via rclone-s3-gateway + ACR (uses `charts/daytona-region/`)
- [`gcp.md`](gcp.md) — GKE Standard + GCS interop + HMAC keys (uses `charts/daytona-region/`)

### Shape 2: FULL OSS self-hosted (no Daytona Cloud)

Everything in your cluster: API + Postgres + Redis + MinIO + Harbor + Dex + proxy + runner. No external dependencies beyond DNS + Let's Encrypt. Currently Azure only.

- [`azure-oss.md`](azure-oss.md) — AKS full self-hosted (uses `charts/daytona/` with all 4 subcharts enabled)

> Note: `e2e.sh` in each cloud's setup dir is the **legacy SDK smoke test** retained from the pre-K8s flow. It still works — it just creates/deletes sandboxes via the Daytona API. The new K8s-native entrypoint is `up.sh`, NOT `e2e.sh`.

## Troubleshooting

See [`troubleshooting.md`](troubleshooting.md) for common failure modes (LoadBalancer stuck pending, cert-manager challenge timeouts, runner CrashLoopBackOff, sandbox build 403s, DNS-01 wildcard upgrade path).

## What "done" looks like for Prompt 1

You can create a sandbox via the web UI and it reaches `Ready` state without errors. That confirms:

- The runner DaemonSet is up and registered with Daytona Cloud (S2)
- The chart's K8s-native runner main container path works (S2)
- The snapshot manager can read/write the customer-owned bucket (S6, S5)
- The proxy ingress + TLS + DNS chain resolves end-to-end
- The host-side `nsenter` docker + sysbox bootstrap completed on the node (S3 + S4 + AKS tarball fallback)

If any of the above fails, capture the failure into `docs/upstream-issues/` in the helm-charts repo and reference it when filing the upstream issue at <https://github.com/daytonaio/daytona/issues>.

## What's intentionally NOT covered in Prompt 1

- IRSA / Workload Identity for the runner (chart side wired; runtime works only when the upstream daytona-runner accepts the default credential chain — see [`docs/upstream-issues/runner-irsa-support.md`](../../fork/helm-charts/docs/upstream-issues/runner-irsa-support.md))
- DNS-01 wildcard TLS certificate (HTTP-01 used for v1 — covers `proxy.<base>` + `snapshots.<base>` but not `*.proxy.<base>`)
- Snapshot-manager IRSA / Workload Identity (Prompt 2)
- Fractional vCPU / 100-sandboxes-per-node sizing (Prompt 2)
- Sandbox egress hardening / DNS hardening (Prompt 2)
- BYOC warm pooling (Prompt 3)

## Where to file findings

- Chart-side bugs: open an issue against `dalinkstone/helm-charts` referencing the failing scenario from this doc.
- Upstream daytona-runner / API bugs: open an issue against `daytonaio/daytona`; the drafts in [`docs/upstream-issues/`](../../fork/helm-charts/docs/upstream-issues/) of the helm-charts repo are starting points.
- Test-script bugs: open an issue against `dalinkstone/helm-charts` with the cloud, prompt set, and exact failing command.
