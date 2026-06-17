# Daytona FULL OSS Self-Hosted on Azure AKS

Single interactive script that creates an AKS cluster + deploys the **full self-hosted Daytona OSS** (API + Postgres + Redis + MinIO + Harbor + Dex + proxy + runner). No Daytona Cloud control plane. No external rclone gateway. Everything runs inside your AKS cluster.

> **This is NOT the BYOC region path.** For compute-only BYOC (control plane stays in Daytona Cloud) on Azure, see [`azure.md`](azure.md).

## Prerequisites

| Tool | Check |
|---|---|
| `az` | `az --version` |
| `kubectl`, `helm`, `envsubst`, `yq`, `jq`, `openssl` | see [`README.md`](README.md) |

Azure account:

```bash
az login
az account show
```

Required roles on the subscription: `Contributor` (or finer-grained: RG + AKS + storage + networking).

DNS: a base domain you control (e.g. `daytona.mycompany.com`). The script will print the records you must create after the LoadBalancer is up.

## Run

```bash
cd ~/main/fork/helm-charts
bash scripts/azure-oss-setup/up.sh
```

You'll be prompted for:

| Prompt | Default | Notes |
|---|---|---|
| Cluster name | `daytona-oss-<timestamp>` | |
| Public base DNS domain | — | e.g. `daytona.mycompany.com` |
| Email for Let's Encrypt | — | |
| Azure region | `eastus` | |
| Resource group | `<cluster>-rg` | |
| Daytona image tag |  `v0.184.0-k8s-oss.1-amd64` | Applied to api/proxy/runner/runnermanager/ssh-gateway via values-oss.yaml.tmpl |

**Postgres / Redis / MinIO / Harbor admin passwords are auto-generated** and saved to `scripts/azure-oss-setup/.state/oss-secrets.env` (mode 0600). Back that file up before teardown if you want to restore data — teardown wipes the resource group.

## What the script does

1. **Resource group** + **AKS cluster** with `--enable-oidc-issuer --enable-workload-identity --os-sku Ubuntu2404`. ~10-15 min.
2. **Sandbox node pool** with `daytona-sandbox-c=true` label + `sandbox=true:NoSchedule` taint, also on Ubuntu 24.04.
3. **kubeconfig** via `az aks get-credentials`.
4. **Ubuntu 24.04 verifier** runs immediately after node pool join for all AKS nodes, then again for sandbox-labeled nodes. NO EXCEPTIONS — aborts if anything else.
5. **daytona namespace** created.
6. **ingress-nginx** + **cert-manager** + Let's Encrypt ClusterIssuer.
7. **LoadBalancer wait** for the Azure standard LB hostname.
8. **DNS records** printed (only 2: base + wildcard).
9. **`helm dependency build`** pulls in postgres + redis + minio + harbor subcharts.
10. **`helm install daytona`** with the rendered OSS values. Wait timeout 20 min (subcharts are heavy).

## DNS records (just 2 — much simpler than BYOC)

The script prints something like:

```
daytona.mycompany.com        A or CNAME   abc.eastus.cloudapp.azure.com
*.daytona.mycompany.com      A or CNAME   abc.eastus.cloudapp.azure.com
```

The **wildcard** catches:

- Sandbox subdomains (`<sandbox-id>.daytona.mycompany.com`)
- Dex auth (`dex.daytona.mycompany.com`)
- Harbor registry (`harbor.daytona.mycompany.com`)

That's it. Two DNS records cover the entire deployment.

## Verify

```bash
# All pods Running?
kubectl -n daytona get pods

# All subchart PVCs bound?
kubectl -n daytona get pvc

# API reachable + TLS valid?
curl -fsv https://daytona.mycompany.com/health 2>&1 | head -30

# Harbor reachable?
curl -fsv https://harbor.daytona.mycompany.com/api/v2.0/health 2>&1 | head -10

# Dex reachable?
curl -fsv https://dex.daytona.mycompany.com/healthz 2>&1 | head -10

# Runner DaemonSet ready (Ubuntu 24.04 + AKS tarball fallback fired)?
kubectl -n daytona logs daemonset/daytona-runner -c docker-installer --tail=50 | \
  grep -E 'static.*tarball|dockerd not installed by deb'

# Smoke test (infra reachability):
bash scripts/azure-oss-setup/e2e.sh
```

## First-time admin setup

1. Open `https://<base-domain>` in a browser.
2. The chart's API initializes the first admin user on first visit (via dex).
3. Open `https://harbor.<base-domain>`, log in as `admin` with the auto-generated `HARBOR_ADMIN_PASSWORD` from `.state/oss-secrets.env`.
4. Create a sandbox via the Daytona dashboard at `https://<base-domain>`.

If the sandbox reaches "Ready" within ~60-90 seconds, the test PASSES.

## Teardown

```bash
bash scripts/azure-oss-setup/teardown.sh
```

1. Helm uninstalls `daytona` (drains postgres / redis / minio / harbor PVCs).
2. Deletes the `daytona` namespace.
3. `az group delete --no-wait` (~10-15 min) — removes AKS + node pools + storage + LB.
4. Cleans up `.state/` and kubeconfig contexts.

> **The `oss-secrets.env` file is deleted with `.state/`.** If you want to recover data later, back up `.state/oss-secrets.env` AND the underlying postgres / minio PVC snapshots BEFORE running teardown.

## Hard constraints (NO EXCEPTIONS — same as BYOC azure-setup)

- **Ubuntu 24.04 on every AKS node** — enforced via `omc::verify_node_ubuntu` post-create, with a second sandbox-selector gate.
- **Daytona components at v0.184.0** (Chart.AppVersion + explicit tag pins in values.yaml; the OSS-flavored images are `v0.184.0-k8s-oss.1-amd64` (the `.3` patch has a runner heartbeat bug)).
- **Python SDK at `daytona==0.183.*`** (set in `e2e.sh` install hint).
- **K8s-native install only** — `install.sh` on a VM is intentionally not in the flow.

## Known operational gaps

- **No HA for Postgres/Redis/MinIO/Harbor** by default — each is a single replica (sufficient for testing, not production).
- **PVC backup** is your responsibility. The chart enables persistence (`postgresql.primary.persistence.enabled: true` etc.) but doesn't manage snapshots.
- **Dashboard URL collision with API URL** — both at `https://<base-domain>` — the chart resolves this via path-based routing. If you see a 404, check the API ingress rules with `kubectl -n daytona get ingress`.

## Recovery from a partial up.sh failure

`up.sh` is idempotent. Just re-run:

```bash
bash scripts/azure-oss-setup/up.sh
```

It will skip steps whose resources already exist. The `.state/oss-secrets.env` persists across reruns so the generated passwords match the actual deployed values.

If you want a full reset:

```bash
bash scripts/azure-oss-setup/teardown.sh
rm -rf scripts/azure-oss-setup/.state/
bash scripts/azure-oss-setup/up.sh
```

## State files

| File | Mode | Purpose |
|---|---|---|
| `scripts/azure-oss-setup/.state/prompts.env` | 600 | Prompt answers |
| `scripts/azure-oss-setup/.state/oss-secrets.env` | 600 | Auto-generated subchart admin passwords |
| `scripts/azure-oss-setup/.state/values-oss.yaml` | 600 | Rendered helm values (contains all secrets) |
