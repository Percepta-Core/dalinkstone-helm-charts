# Daytona BYOC on Azure — Customer Journey Reproducer

This reproducer walks through what a real Daytona Cloud customer experiences
when adopting **Customer Managed Compute (BYOC)** on Azure. The goal is to
make the friction points concrete, not just to ship working scripts.

## What BYOC actually is

A BYOC customer uses **Daytona Cloud** (`app.daytona.io`) as their control
plane but runs the underlying **compute** in their own cloud account. They do
this by creating a custom *region* and then attaching one or more *runners*
to it.

```
         ┌─────────────────────────────────────────────────────────┐
         │                 Daytona Cloud (app.daytona.io)          │
         │  - Dashboard, API, auth, snapshot index, billing        │
         │  - Knows about your custom region by name + proxyUrl    │
         └────────────────────────┬────────────────────────────────┘
                                  │ HTTPS
                  ┌───────────────┴──────────────────┐
                  │ (1) SDK call: daytona.create(    │
                  │       target="my-aks-region")    │
                  │                                  │
                  ▼                                  ▼
   ┌──────────────────────────┐         ┌─────────────────────────┐
   │  Your AKS cluster        │         │  Your runner VM(s)      │
   │  ────────────────        │         │  ──────────────         │
   │  - daytona-region chart  │         │  - daytona-runner binary│
   │    - proxy               │◄────────┤    + systemd            │
   │    - snapshot-manager    │  HTTPS  │  - Docker + sysbox      │
   │  - ingress-nginx         │         │  - sandbox containers   │
   │  - cert-manager          │         │    run HERE             │
   │  - rclone S3 gateway     │         │                         │
   │  - Azure Blob storage    │         │                         │
   └──────────────────────────┘         └─────────────────────────┘
```

Daytona Cloud routes the customer's SDK calls (or dashboard actions) through
the customer's proxy (running in AKS), which forwards them to one of the
customer's runner VMs, which runs the actual sandbox container locally.

## The 18 steps a real customer goes through

In practice — even with this reproducer automating most of it — these are the
actual decisions and actions involved.

| # | Step | Automated by this repro? |
|---|---|---|
| 1 | Sign up at daytona.io | ❌ Interactive web flow |
| 2 | Create an organization | ❌ Dashboard click |
| 3 | Find and generate a personal API key at `app.daytona.io/dashboard/keys` | ❌ Manual; **the BYOC docs don't link to this page** |
| 4 | Pick a region name (lowercase, alphanumeric + `.-_`) | ✅ Auto-generated `aks-cmc-<timestamp>` |
| 5 | Pick a proxy URL (FQDN you own) | ❌ You provide `DOMAIN` env var |
| 6 | (Optional) Pick a snapshot manager URL | ✅ Derived as `snapshots.${DOMAIN}` |
| 7 | (Optional) Set up S3-compatible storage for snapshots | ✅ Azure Blob + rclone S3 gateway in cluster |
| 8 | Provision the AKS cluster | ✅ `az aks create` |
| 9 | Point DNS at the cluster's ingress LB | ✅ Cloudflare API |
| 10 | Install ingress-nginx | ✅ helm |
| 11 | Install cert-manager + ClusterIssuer for wildcard TLS | ✅ DNS-01 against Cloudflare |
| 12 | Install `daytona-region` chart (registers region, brings up proxy + snapshot-manager) | ✅ helm install |
| 13 | Realize the chart didn't deploy runners | ✅ This README + script tell you |
| 14 | Provision runner VM(s) | ✅ `az vm create` |
| 15 | SSH or run-command to install Docker + sysbox + daytona-runner binary | ✅ `az vm run-command` + bootstrap script |
| 16 | Register the runner via `install.sh` (which POSTs to `/api/runners`) | ✅ env-vars passed to install.sh |
| 17 | Wait for the runner to appear "ready" in the dashboard | ✅ Polled via API |
| 18 | Validate with the SDK | ✅ `e2e.sh` runs `daytona.create(target=<region>)` |

## The pain points worth seeing for yourself

This is what makes BYOC harder than the marketing suggests. Each one is real,
and each surfaces during this repro.

1. **The `daytona-region` chart name implies it includes runners. It does not.**
   This is the most common BYOC stumble. The chart deploys proxy + snapshot
   manager only. You will see your chart install succeed, region appear in
   the dashboard, and then `daytona.create(target=region)` fail with "no
   available runners" until you do the VM step.

2. **Two different `dtn_xxx` API keys.** The *customer/org* key is used by
   the chart to register the region. The *runner* key is returned when you
   register a runner. The CLI/install.sh prompts for "Admin API Key" which
   means the customer key — the runner key is then generated and stored in
   `/etc/daytona/runner.env`. They look identical (`dtn_...`) so it's easy
   to use the wrong one.

3. **No AKS-native runner deployment exists.** Daytona ships a Terraform
   module for AWS EC2 and `install.sh` for any Linux VM. There's no AKS
   DaemonSet / managed identity / Azure-native path. So even on AKS-native
   BYOC, the runner ends up on a *separate* Azure VM, not inside the AKS
   cluster.

4. **Azure Blob doesn't natively speak S3.** The snapshot manager only
   speaks S3. For Azure customers, this means deploying a shim like rclone's
   S3 gateway (this repro) or paying for a real S3-compatible service
   (Wasabi, Backblaze). MinIO's Azure gateway is deprecated.

5. **The wildcard proxy URL needs DNS-01 TLS.** `proxy.example.com` and
   `*.proxy.example.com` must both have a trusted cert. HTTP-01 doesn't
   cover wildcards, so you need DNS-01, so you need an API token for your
   DNS provider. Same friction we hit on the on-prem repro.

6. **`helm uninstall` does NOT clean up Daytona Cloud state.** The region
   you registered stays in Daytona Cloud's database. Runners likewise. You
   have to call the API or visit the dashboard. The teardown script in this
   repo handles this; the chart's README mentions it in a note that's easy
   to miss.

7. **Region registration is fragile to re-runs.** Helm's pre-install hook
   sees that the secret already exists and skips re-registration — but if
   you change the proxy URL, it doesn't update the API. You'd have to
   manually `PATCH /api/regions/<id>` or delete + recreate.

8. **No way to validate the region in isolation.** Until at least one
   runner is registered and reports "ready", `daytona.create(target=region)`
   will fail. So "did my chart install work?" can only be answered by
   completing the entire VM step too.

## What this reproducer requires

| Thing | Where it comes from |
|---|---|
| `DAYTONA_API_KEY` | Generate at https://app.daytona.io/dashboard/keys |
| `DOMAIN` | A subdomain you own under a Cloudflare-managed zone (e.g. `cmc.yourdomain.com`) |
| `ACME_EMAIL` | Anything — used for Let's Encrypt registration |
| `CLOUDFLARE_API_TOKEN` | https://dash.cloudflare.com/profile/api-tokens — "Edit zone DNS" template, scoped to your zone |
| Azure subscription | Must be PAYG or similar; Azure-for-Students has SKU/quota issues |

## How to run

```bash
cd scripts/azure-setup/test

export DAYTONA_API_KEY='dtn_paste-personal-key-here'
export DOMAIN='cmc.yourdomain.com'
export ACME_EMAIL='you@yourdomain.com'
export CLOUDFLARE_API_TOKEN='paste-cf-token'

# First full run - everything end to end (~35-45 min including AKS provision)
./repro.sh

# Iterate by phase:
PHASE=1 ./repro.sh    # just up to cert-manager + namespace + Certificates
PHASE=2 ./repro.sh    # also blob storage + rclone gateway
PHASE=3 ./repro.sh    # also helm install (region registered, no runner yet)
PHASE=4 ./repro.sh    # also runner VM provision (no bootstrap yet)
PHASE=5 ./repro.sh    # full end-to-end (default)

# When done:
./teardown.sh
```

## Layout

```
azure-repro/
├── repro.sh                       # main provision script (15 phases)
├── teardown.sh                    # cleanup: deletes runner + region from
│                                  # Daytona Cloud, RG from Azure, A records
│                                  # from Cloudflare, local state.
├── values-region.yaml.tmpl        # daytona-region helm values (envsubst'd
│                                  # with DOMAIN, REGION_NAME, API creds, etc.)
├── rclone-deployment.yaml.tmpl    # rclone S3-gateway over Azure Blob
├── runner-bootstrap.sh            # runs on the runner VM via az vm run-command;
│                                  # presets every env var install.sh checks
│                                  # for, then runs daytona's install.sh
│                                  # non-interactively.
├── e2e.sh                         # SDK test: daytona.create(target=region)
│                                  # then code_run("print('Hello World')")
└── .state/                        # generated at runtime (region-id, names,
                                   # rclone keys, rendered manifests). gitignore.
```

## Validating each phase

At the end of every phase, you can spot-check:

```bash
# Phase 1: namespace exists, certificates issuing
kubectl get ns daytona-region
kubectl -n daytona-region get certificate

# Phase 2: rclone gateway accessible from inside the cluster
kubectl -n daytona-region exec -it deploy/rclone-s3-gateway -- \
  rclone lsd azureblob:

# Phase 3: region registered in Daytona Cloud
curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" \
  https://app.daytona.io/api/regions | jq '.[] | {name, id, proxyUrl}'

# Phase 4: runner VM running
az vm show --resource-group daytona-cmc-rg --name daytona-cmc-runner \
  --query "{name:name, ip:publicIps, state:provisioningState}" -d -o table

# Phase 5: runner registered, state=ready
curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" \
  https://app.daytona.io/api/runners | jq '.[] | {id, name, state, score:.availabilityScore}'
```

## Comparison to the on-prem reproducer

The full-OSS deployment (see [`scripts/azure-oss-setup/`](../../azure-oss-setup/))
self-hosts the **entire** Daytona stack (control plane + runners + everything).
This BYOC reproducer self-hosts only the **compute** half — control plane stays
at `app.daytona.io`. They're different deployment models and serve different
customer needs:

|   | on-prem (`daytona` chart) | BYOC (`daytona-region` chart) |
|---|---|---|
| Control plane | Self-hosted on AKS | Daytona Cloud (`app.daytona.io`) |
| API key source | Generated by self-hosted Dex | Daytona Cloud dashboard |
| Postgres / Redis / Harbor | Bundled subcharts | Not needed |
| Runners | DaemonSet inside AKS | Separate Azure VMs |
| When to use | Air-gapped, full data residency, no upstream dependency | Want managed control plane, want compute on your network |

## Known gaps in this reproducer

- **rclone S3 gateway TLS.** The gateway listens on plain HTTP inside the
  cluster (`secure: false` in values). Fine for testing, but for production
  the snapshot manager → rclone link should be TLS.
- **Single runner.** Most BYOC deployments run multiple runners for scale +
  HA. Adding more is `az vm create` + bootstrap, but this repro shows one.
- **VM SKU choice is opinionated.** `Standard_D4s_v3` is 4 vCPU / 16 GiB —
  good for a few small sandboxes. Real workloads usually want bigger.
- **No `apiVersion` configuration.** The runner uses install.sh's default
  apiVersion. Admin runner endpoints require explicit apiVersion 0 or 2;
  this matters if you ever switch to manual registration.

## When you've finished running it

You will have:
1. A working BYOC region on AKS + a runner on a separate Azure VM
2. Working SDK calls targeting your custom region
3. Direct experience with all 8 pain points listed above

You can then either tear down (cheapest), keep it running to demo someone
else (~$0.50/hr for AKS + VM combined), or iterate by running individual
phases as you experiment with config changes.
