# Daytona BYOC test — Azure / AKS

Single interactive script that creates an AKS cluster, Azure Storage Account, in-cluster `rclone-s3-gateway` shim, and deploys the daytona-region helm chart. Exercises the AKS-specific docker-installer tarball fallback (Prompt 1 commit d1892ef).

## Prerequisites

| Tool | Check |
|---|---|
| `az` | `az --version` |
| `kubectl`, `helm`, `envsubst`, `yq`, `jq`, `openssl` | see [`README.md`](README.md) |

Azure account:

```bash
az login
az account show       # confirm the right subscription
```

The user running `up.sh` needs: `Contributor` on the subscription (or at minimum: RG create/delete, AKS create, storage account create, ACR create-attach). DNS is operator-side; the script prints the records.

## Run

```bash
cd ~/main/fork/helm-charts
bash scripts/azure-setup/up.sh
```

Prompts (defaults in `[brackets]`):

| Prompt | Default | Notes |
|---|---|---|
| Cluster name | `daytona-byoc-<timestamp>` | AKS cluster name |
| Public base DNS domain | — | e.g. `byoc.example.com` |
| Daytona region name | `<cluster>` | |
| Email for Let's Encrypt | — | |
| Daytona Cloud API URL | `https://api.daytona.io` | |
| Daytona Cloud admin API key | — | **secret** |
| Azure region | `eastus` | |
| Resource group | `<cluster>-rg` | |
| Storage account | `daytonabyoc<random8>` | Globally unique, lowercase alnum 3-24 chars |
| Blob container | `snapshots` | |
| Runner image tag | `v0.183.0` | Default matches chart appVersion |

Answers persist in `scripts/azure-setup/.state/prompts.env`.

## What the script does

1. **Resource group** + **AKS cluster** with `--enable-oidc-issuer --enable-workload-identity --os-sku Ubuntu2404`. ~10-15 min. After cluster create + sandbox node pool join, the `omc::verify_node_ubuntu "24.04"` gates fail-fast if any AKS node reports something other than Ubuntu 24.04 — no exceptions, no override flag.
2. **Sandbox node pool** with `daytona-sandbox-c=true` label + `sandbox=true:NoSchedule` taint.
3. **Storage Account** (Standard_LRS, StorageV2) + **Blob container**.
4. **kubeconfig** via `az aks get-credentials`.
5. **rclone-s3-gateway** deployed in the `daytona` namespace via `rclone-deployment.yaml.tmpl`. Generates ephemeral rclone access/secret pairs (saved 0600 to `.state/rclone-keys.env`). The gateway translates S3-compat API calls to Azure Blob REST.
6. **ingress-nginx** + **cert-manager** + Let's Encrypt ClusterIssuer.
7. **LoadBalancer wait** for the Azure standard LB IP.
8. **DNS records** printed.
9. **`helm install daytona-region`** with the rendered values.

## Verify

```bash
kubectl -n daytona get pods

# Rclone gateway up?
kubectl -n daytona get deploy/rclone-s3-gateway
kubectl -n daytona logs deploy/rclone-s3-gateway --tail=20

# AKS-specific docker-installer tarball fallback fired?
kubectl -n daytona logs daemonset/daytona-region-runner -c docker-installer | \
  grep -E 'static.*tarball|dockerd not installed by deb'
```

**The tarball-fallback log line** is the Prompt 1 d1892ef proof. AKS-managed nodes (Ubuntu 24.04 in current up.sh, since the chart's docker-installer downloads Ubuntu 24.04/noble .deb packages) ship `moby-containerd`, which conflicts with `docker-ce` at apt install time. The docker-installer detects the missing `/usr/bin/dockerd` after the deb step and falls back to installing Docker from the official static tarball at `download.docker.com/linux/static/stable/x86_64/docker-27.4.1.tgz`. EKS + GKE don't hit this path; AKS does. The up.sh script enforces `--os-sku Ubuntu2404` + `omc::verify_node_ubuntu` gates that refuse to continue if any AKS node isn't on Ubuntu 24.04.

## Smoke test

Same as AWS — open <https://app.daytona.io/dashboard/sandboxes> and create a sandbox in your BYOC region. Expected `Ready` within ~60s (note: first sandbox after install may take longer if the docker-installer is still running on the node).

Programmatic:

```bash
export DAYTONA_API_URL=https://api.daytona.io
export DAYTONA_API_KEY=<your-key>
export REGION_NAME=<region-name>
bash scripts/azure-setup/e2e.sh
```

## Teardown

```bash
bash scripts/azure-setup/teardown.sh
```

1. Helm uninstalls daytona-region
2. Deletes daytona namespace (also removes rclone-s3-gateway)
3. `az group delete --no-wait` — nuclear; removes AKS + storage + LB + everything in the RG. ~10-15 min async.
4. Cleans up `.state/` and kubeconfig contexts.

Confirm with `az group show --name <rg>` → `ResourceGroupNotFound`.

## Known gaps (Prompt 1)

- **Azure Blob is not natively S3-compatible**, hence the `rclone-s3-gateway` shim. This is intentional for Prompt 1; native Azure Workload Identity wiring is Prompt 2.
- **rclone-s3-gateway is a single deployment** with no HA replication; for production multi-tenant tests, scale or replace with a real S3-compatible service.
- **Static keys only** for runner AWS env — Azure Workload Identity for the runner pod is Prompt 2.

## State files

| File | Mode | Purpose |
|---|---|---|
| `scripts/azure-setup/.state/prompts.env` | 600 | Prompt answers |
| `scripts/azure-setup/.state/rclone-keys.env` | 600 | Generated rclone gateway credentials |
| `scripts/azure-setup/.state/rclone-deployment.yaml` | 600 | Rendered rclone manifest (contains storage account key) |
| `scripts/azure-setup/.state/values-region.yaml` | 600 | Rendered helm values (contains rclone secret + Daytona API key) |
