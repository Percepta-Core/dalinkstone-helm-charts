# Daytona FULL OSS Self-Hosted on Azure AKS

K8s-native bring-up of the **full self-hosted Daytona OSS** on AKS. Everything
runs inside the cluster (API, Postgres, Redis, MinIO, Harbor, Dex auth,
runner, proxy). No Daytona Cloud control plane. No external dependencies
beyond DNS + your chosen TLS provider.

> **This is NOT the BYOC region path.** For BYOC (compute-only, control plane
> in Daytona Cloud) on Azure, use [`../azure-setup/`](../azure-setup/) instead.

---

## Prerequisites

Install these locally before running any script:

```bash
# macOS
brew install azure-cli kubectl helm gettext yq jq openssl
# (envsubst comes from gettext on macOS)

# Linux (Ubuntu/Debian)
sudo apt-get install -y azure-cli kubectl gettext-base yq jq openssl
curl https://baltocdn.com/helm/signing.asc | sudo apt-key add - && \
  echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list && \
  sudo apt-get update && sudo apt-get install -y helm
```

Also required:
- Azure CLI logged in: `az login` (or `az login --tenant <tenant-id>`)
- A public DNS domain you control (e.g. `daytona.mycompany.com`)
- **For Cloudflare TLS mode** (recommended): a Cloudflare account managing
  the DNS zone for your base domain + an API token with `Zone:Read` +
  `Zone DNS:Edit` permissions scoped to that zone. See
  [Cloudflare token setup](#cloudflare-api-token-setup) below.

---

## Quick start

```bash
cd ~/main/fork/helm-charts        # or wherever you cloned the repo
bash scripts/azure-oss-setup/up.sh
```

The script is interactive — it walks you through 10 steps and prompts for
configuration along the way. Total runtime: **15-25 minutes** on a clean
subscription (most of the time is AKS provisioning + Harbor pod settle).

### Prompts you'll be asked

1. **Cluster name** — default: `daytona-oss-<timestamp>`
2. **Public base DNS domain** — e.g. `daytona.mycompany.com`
3. **TLS strategy** — choose ONE:
   - `cloudflare-dns01` — automatic Let's Encrypt via Cloudflare DNS-01
     (**recommended for production**; handles the chart's wildcard SAN
     correctly; only DNS-01 can issue wildcard certs per LE policy)
   - `self-signed` — chart generates self-signed certs at install time
     (browser warnings on every visit; **dev/test only**)
   - `manual` — you pre-create the TLS Secrets in the `daytona` namespace
     (you manage cert rotation; advanced)
4. **Azure region** — default: `eastus`
5. **Azure resource group** — default: `<cluster-name>-rg`
6. **Daytona image tag** — default: `v0.184.0-k8s-oss.1-amd64` (the `-k8s-oss.3` patch ships a runner v2-healthcheck goroutine bug that silently stops sending heartbeats after the first one, causing UNRESPONSIVE flips and default-snapshot cleanup; `daytona-runner-manager` has no v0.183.x tags so a full v0.183 revert isn't possible — `.1` is the highest stable k8s-oss patch shared by all 5 service images)
7. **(Cloudflare mode only) Let's Encrypt email** — for cert expiry warnings
8. **(Cloudflare mode only) Cloudflare API token** — hidden input
9. **DNS confirmation** — after the LoadBalancer hostname is printed, you
   create two DNS records (base + wildcard) and confirm

Choices persist in `scripts/azure-oss-setup/.state/prompts.env` (mode 0600)
so re-running picks up where you left off. Secrets persist in
`.state/oss-secrets.env` (also mode 0600). `.state/` is gitignored repo-wide.

---

## Cloudflare API token setup

Skip this section if you're using `self-signed` or `manual` TLS modes.

1. Sign in to <https://dash.cloudflare.com/profile/api-tokens>
2. Click **Create Token**
3. Use the **"Edit zone DNS"** template
4. Configure:
   - **Permissions**: `Zone:Read` + `Zone DNS:Edit`
   - **Zone Resources**: Include → Specific zone → select your base domain's zone
5. **Continue to summary** → **Create Token**
6. **Copy the token immediately** — Cloudflare only shows it once
7. Paste it when `up.sh` prompts for `CLOUDFLARE_API_TOKEN` (hidden input)

The token is stored in `.state/oss-secrets.env` (mode 0600). To rotate later,
delete that line and re-run `up.sh`.

---

## DNS records

After `up.sh` provisions ingress-nginx, it prints two DNS records you need to
create:

```
<base-domain>     A or CNAME  → <LB-hostname>   (api + dashboard + dex)
*.<base-domain>   A or CNAME  → <LB-hostname>   (proxy + sandbox subdomains + harbor)
```

Both must point at the AKS ingress LoadBalancer (the script prints the exact
hostname).

**Important for Cloudflare users**: set both DNS records to **gray cloud
(DNS only)** during initial install. cert-manager's DNS-01 challenge works
correctly with gray cloud. After install completes and the LE cert is issued,
you can OPTIONALLY flip them to orange cloud (proxied) with Cloudflare
SSL/TLS mode = "Full (strict)" for production traffic.

---

## After `up.sh` completes — validate

The new infra test framework gives you hard-fail assertions for everything
that's expected to be working:

```bash
# Hard-fail validation: pods Ready, runner READY in DB, cert real, token wiring correct
bash scripts/azure-oss-setup/test/infra/fresh-install-validate.sh
```

Expected output: every check `PASS [...]`, exit code 0. If any check fails,
the script tells you what's broken and points at the diagnostic.

For deeper inspection any time:

```bash
# 8-step diagnostic — runner table, env wiring, cert issuer, recent logs
bash scripts/azure-oss-setup/test/infra/diagnose.sh
```

---

## Create your first sandbox (smoke test)

```bash
cd scripts/azure-oss-setup/test

# 1. Generate an admin API key in the dashboard:
#    open https://<your-base-domain>/dashboard
#    Sign in with Dex → User Settings → API Keys → Create new key

# 2. Save credentials to .state/sandbox-test.env (NOT in this directory)
bash init-test-env.sh

# 3. Install Python deps
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 4. Run the smoke test
python test_sandbox.py
```

Expected output ends with `PASS - smoke test complete. No leftover state.`

If you get `SSL: CERTIFICATE_VERIFY_FAILED ... self-signed certificate`,
cert-manager is still working — wait 1-2 minutes and retry, OR set
`DAYTONA_INSECURE_SKIP_VERIFY=1` in `.state/sandbox-test.env` to bypass
TLS verification temporarily.

---

## Recycle a runner node (infra regression test)

When you replace an AKS node (autoscaler scale-down, drain for maintenance,
explicit `delete-machines`, etc.), the chart's recovery flow must converge:
the new node must come up, the runner DaemonSet must schedule a pod, the
runner must register with the api, and the runner state must reach `READY`.

```bash
# Recycle the first sandbox node (default); whole flow auto-asserted
bash scripts/azure-oss-setup/test/infra/recycle-node.sh

# Or target a specific node
NODE_TO_RECYCLE=aks-sandbox-12345678-vmss000000 \
  bash scripts/azure-oss-setup/test/infra/recycle-node.sh
```

The script:
1. Captures baseline (current sandbox nodes + READY runner count)
2. Drains + `az aks nodepool delete-machines` on the target
3. Waits up to 10 min for AKS to provision a replacement node
4. Waits up to 5 min for the new node to reach Kubernetes `Ready`
5. Waits up to 3 min for the runner DaemonSet to schedule a pod on it
6. Waits up to 10 min for that pod to reach `Ready` (docker-installer
   takes a while on first boot)
7. Waits up to 5 min for the api DB to see a `READY` runner in the region
8. Confirms READY count did not regress

Total budget: 30 min. Exits non-zero on any timeout and prints the runner
table so you can `diagnose.sh` for context.

---

## Teardown

```bash
bash scripts/azure-oss-setup/teardown.sh
```

Helm uninstall first (drains PVCs), then `az group delete --no-wait` nukes
the AKS + storage + LB. Confirm with `az group show --name <rg>` returning
`ResourceGroupNotFound`.

Local state (`.state/*`) is wiped too. **Back up `.state/oss-secrets.env`
before teardown if you need to keep the Harbor admin password, etc.**

---

## Hard constraints (NO EXCEPTIONS)

- Ubuntu 24.04 sandbox nodes — enforced via `omc::verify_node_ubuntu`
  post-create. Other Ubuntu versions will refuse to install.
- Daytona components at v0.184.0 (Chart.AppVersion + explicit tag pins in
  values.yaml + image tag pin in values-oss.yaml.tmpl)
- Python SDK at `daytona==0.184.*` (pinned in test/requirements.txt)
- K8s-native install only — `install.sh` on a VM is intentionally not in
  this flow (use `scripts/azure-setup/` for the BYOC path that ships
  installer-driven runners)

---

## What gets installed

| Component | How | Where (after DNS) |
|---|---|---|
| Daytona API | helm chart (`charts/daytona`) | `https://<base>` |
| Daytona proxy + sandboxes | helm chart | `https://*.<base>` |
| Auth (Dex IdP) | helm chart | `https://dex.<base>` |
| Container registry (Harbor) | subchart | `https://harbor.<base>` |
| PostgreSQL | Bitnami subchart | in-cluster ClusterIP |
| Redis | Bitnami subchart | in-cluster ClusterIP |
| Object storage (MinIO) | MinIO subchart | in-cluster ClusterIP |
| ingress-nginx | helm chart | LoadBalancer + Azure LB |
| cert-manager + ClusterIssuer | helm chart (Cloudflare mode only) | Let's Encrypt DNS-01 via Cloudflare |
| Runner DaemonSet | helm chart | privileged + Ubuntu 24.04 nodes |

---

## Full operator-facing guide

See [`../../docs/byoc-overhaul/azure-oss.md`](../../docs/byoc-overhaul/azure-oss.md)
for verification commands, troubleshooting deep-dives, and recovery paths.

---

## Files in this directory

| File | Purpose |
|---|---|
| `up.sh` | Interactive AKS provisioning + Helm install (10 steps) |
| `teardown.sh` | Helm uninstall + Azure RG delete |
| `e2e.sh` | Reachability smoke (DNS/API/Harbor/Dex pings; non-failing) |
| `values-oss.yaml.tmpl` | Helm values template (envsubst'd by up.sh from prompts.env) |
| `README.md` | This file |
| `test/` | Python sandbox smoke tests + infra/ regression scripts |
| `.tests/oss-prompt-set.env` | Static QA fixture (tracked) — for `check-helm-values-templates.sh` |
| `.state/` | Local runtime state (gitignored) — prompts, secrets, kubeconfig, rendered values |
