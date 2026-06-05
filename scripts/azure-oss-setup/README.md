# Daytona FULL OSS Self-Hosted on Azure AKS

K8s-native bring-up of the **full self-hosted Daytona OSS** on AKS. Everything runs inside the cluster (API, Postgres, Redis, MinIO, Harbor, Dex auth, runner, proxy). No Daytona Cloud control plane. No external dependencies beyond DNS + Let's Encrypt.

> **This is NOT the BYOC region path.** For BYOC (compute-only, control plane in Daytona Cloud) on Azure, use [`../azure-setup/`](../azure-setup/) instead.

## Quick start

```bash
cd ~/main/fork/helm-charts
bash scripts/azure-oss-setup/up.sh
```

You'll be prompted for:

- Cluster name (default: timestamped)
- Public base DNS domain (e.g. `daytona.mycompany.com`)
- ACME email (Let's Encrypt account)
- Azure region (default: `eastus`)
- Resource group (default: `<cluster>-rg`)
- Runner image tag (default: `v0.183.0`)

Postgres / Redis / MinIO / Harbor passwords are **auto-generated** and saved to `.state/oss-secrets.env` (mode 0600). Back that file up before teardown if you want to restore — teardown wipes the resource group.

## What gets installed

| Component | How | Where |
|---|---|---|
| Daytona API | helm chart (`charts/daytona`) | `https://<base>` |
| Daytona proxy + sandboxes | helm chart | `https://*.<base>` |
| Auth (Dex IdP) | helm chart | `https://dex.<base>` |
| Container registry (Harbor) | subchart | `https://harbor.<base>` |
| PostgreSQL | Bitnami subchart | in-cluster ClusterIP |
| Redis | Bitnami subchart | in-cluster ClusterIP |
| Object storage (MinIO) | MinIO subchart | in-cluster ClusterIP |
| ingress-nginx | helm chart | LoadBalancer + Azure LB |
| cert-manager + ClusterIssuer | helm chart | Let's Encrypt HTTP-01 |
| Runner DaemonSet | helm chart | privileged + Ubuntu 24.04 nodes |

## DNS records

Just 2 (operator creates after `up.sh` prints the LB hostname):

- `<base-domain>` → A/CNAME → LB hostname (API + dashboard)
- `*.<base-domain>` → A/CNAME → LB hostname (proxy, dex, harbor, all sandbox subdomains)

## Hard constraints (NO EXCEPTIONS, same as the BYOC azure-setup)

- Ubuntu 24.04 sandbox nodes — enforced via `omc::verify_node_ubuntu` post-create
- Daytona components at v0.183.0 (Chart.AppVersion + explicit tag pins)
- Python SDK at `daytona==0.183.*`
- K8s-native install only — `install.sh` on a VM is intentionally not in the flow

## Teardown

```bash
bash scripts/azure-oss-setup/teardown.sh
```

Helm uninstall first (drains PVCs), then `az group delete --no-wait` nukes the AKS + storage + LB. Confirm with `az group show --name <rg>` returning `ResourceGroupNotFound`.

## Full operator-facing guide

See [`/Users/dalinstone/main/test/byoc-overhaul/azure-oss.md`](../../) for the verification commands, troubleshooting, and recovery paths.
