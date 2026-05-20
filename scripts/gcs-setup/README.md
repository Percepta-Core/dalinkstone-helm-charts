# Daytona BYOC on GCP — Customer Journey Reproducer

This reproducer walks through what a real Daytona Cloud customer experiences
when adopting **Customer Managed Compute (BYOC)** on Google Cloud. The goal
is to ship a working end-to-end deployment AND make the friction points
concrete.

## What BYOC actually is

A BYOC customer uses **Daytona Cloud** (`app.daytona.io`) as their control
plane but runs the underlying **compute** in their own GCP project. They do
this by creating a custom *region* and then attaching one or more *runners*
to it.

```
         ┌─────────────────────────────────────────────────────────┐
         │                 Daytona Cloud (app.daytona.io)          │
         │  - Dashboard, API, auth, snapshot index, billing        │
         │  - Knows about your custom region by name + proxyUrl    │
         └────────────────────────┬────────────────────────────────┘
                                  │ HTTPS (outbound only)
                  ┌───────────────┴──────────────────┐
                  │ (1) SDK call: daytona.create(    │
                  │       target="my-gke-region")    │
                  │                                  │
                  ▼                                  ▼
   ┌──────────────────────────┐         ┌─────────────────────────────┐
   │  Your GKE cluster        │         │  Your runner GCE instances  │
   │  (proxy + snapshot-mgr)  │         │  (4 × n2-standard-8)        │
   │  - daytona-region chart  │◄────────┤  - daytona-runner systemd   │
   │    - proxy               │  HTTPS  │  - Docker + sysbox          │
   │    - snapshot-manager    │         │  - sandbox containers       │
   │  - ingress-nginx (LB)    │         │    run HERE                 │
   │  - cert-manager          │         │                             │
   └──────────────────────────┘         └─────────────────────────────┘
                  │                                  │
                  └───────────────┬──────────────────┘
                                  ▼
                       ┌─────────────────────┐
                       │  GCS bucket (yours) │
                       │  - snapshot blobs   │
                       │  - builder context  │
                       └─────────────────────┘
```

Daytona Cloud routes the customer's SDK calls (or dashboard actions) through
the customer's proxy (running in GKE), which forwards them to one of the
customer's runner GCE instances, which runs the actual sandbox container
locally. The snapshot-manager (in GKE) and every runner (on GCE) read and
write the same customer-owned GCS bucket via the **GCS interop XML API**
using HMAC keys — so the chart's S3-only snapshot-manager works unmodified.

## Secret handling

**No secret is ever passed on a command line, written to a long-lived disk
file, or echoed to a log.** All cross-runner and cross-pod secrets live in
**Google Secret Manager**. Each runner VM is granted `secretAccessor` on
exactly the secrets it needs, and the bootstrap script on each runner
fetches them at the last possible moment using the instance's service
account (no SSH-side secret transit).

What that means in practice:

- **HMAC access / secret keys**: generated locally, immediately stored in
  Secret Manager, then `shred`'d from local memory before the rest of the
  script runs. The values-rendered helm values file lives only in
  `mktemp -d`-backed memory during `helm install`, then is `shred`'d.
- **Daytona runner API keys** (`dtn_xxx`): the per-runner token returned
  by `POST /api/runners` is stored directly in Secret Manager and pulled
  by that runner's bootstrap. Never present in any SSH payload.
- **DAYTONA_API_KEY** (the customer's *org* key): used only locally in
  this script process — the `helm install` consumes it via stdin/`--set`
  pipe (not `-f`), and it's never present in the runner-side payload.
- **CLOUDFLARE_API_TOKEN**: handed off to cert-manager once via a
  k8s Secret (server-side encrypted by GKE), then forgotten by the script.

The `.state/` directory holds resource names and IDs only — never raw
secret values.

## The 16 steps a real customer goes through

In practice — even with this reproducer automating most of it — these are
the actual decisions and actions involved.

| # | Step | Automated by this repro? |
|---|---|---|
| 1 | Sign up at daytona.io | ❌ Interactive web flow |
| 2 | Create an organization | ❌ Dashboard click |
| 3 | Generate a personal API key at `app.daytona.io/dashboard/keys` | ❌ Manual; the BYOC docs don't link to this page |
| 4 | Pick a region name (lowercase, alphanumeric + `.-_`) | ✅ Auto-generated `gke-cmc-<timestamp>` |
| 5 | Pick a proxy URL (FQDN you own) | ❌ You provide `DOMAIN` |
| 6 | Set up GCS bucket + HMAC keys for snapshots + builder | ✅ `gcloud storage buckets create` + service account + HMAC key |
| 7 | Enable APIs (container, compute, secretmanager, iap, storage) | ✅ `gcloud services enable` |
| 8 | Provision the GKE Standard cluster | ✅ `gcloud container clusters create` |
| 9 | Point DNS at the cluster's LB IP | ✅ Cloudflare API A records |
| 10 | Install ingress-nginx (cloud-LB-backed) | ✅ helm |
| 11 | Install cert-manager + ClusterIssuer for wildcard TLS | ✅ DNS-01 against Cloudflare |
| 12 | Install `daytona-region` chart (registers region, brings up proxy + snapshot-manager) | ✅ helm install |
| 13 | Realize the chart didn't deploy runners | ✅ This README + script tell you |
| 14 | Pick runner machine type from your remaining vCPU quota | ✅ Interactive — script queries quota and shows what fits |
| 15 | Provision runner GCE instances | ✅ `gcloud compute instances create` × `RUNNER_COUNT` |
| 16 | Bootstrap each runner: install Docker + sysbox + daytona-runner; register via `/api/runners` | ✅ `gcloud compute ssh --tunnel-through-iap` + bootstrap script (pulls HMAC + token from Secret Manager on the box) |
| 17 | Validate with the SDK | ✅ `e2e.sh` runs `daytona.create(target=<region>)` |

## Pain points worth seeing for yourself

This is what makes BYOC harder than the marketing suggests. Each one is real,
and each surfaces during this repro.

1. **The `daytona-region` chart name implies it includes runners. It does not.**
   This is the most common BYOC stumble. The chart deploys proxy +
   snapshot-manager only. The chart install succeeds, the region appears in
   the dashboard, and then `daytona.create(target=region)` fails with "no
   available runners" until you do the GCE step.

2. **The declarative builder needs storage credentials wired up in two places, not one.**
   The snapshot-manager (in GKE) gets its credentials from
   `services.snapshotManager.storage.s3.*` in helm values. Every runner GCE
   instance ALSO needs `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/
   `AWS_DEFAULT_BUCKET`/`AWS_REGION`/`AWS_ENDPOINT_URL` env vars (yes —
   AWS_*, even on GCP — the runner binary uses an S3 client) in
   `/etc/systemd/system/daytona-runner.service`. They must point at the
   same bucket. If they don't, snapshot creation via
   `Image.debian_slim(...).pip_install(...)` fails with a 403 at the
   inspect/build step.

3. **GCS HMAC keys are per-service-account, but Daytona expects AWS-shaped
   env vars.** The clean path is: create a dedicated service account, mint
   HMAC keys for it, grant it `roles/storage.objectAdmin` on the bucket,
   point `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` at those keys, and
   set `AWS_ENDPOINT_URL=https://storage.googleapis.com`. This repro does
   exactly that.

4. **Two different `dtn_xxx` API keys.** The *customer/org* key is used by
   the chart to register the region. The *runner* key is returned when you
   register a runner. The CLI/`install.sh` prompts for "Admin API Key"
   which means the customer key — the runner key is then generated and
   stored in `/etc/daytona/runner.env`. They look identical (`dtn_...`) so
   it's easy to use the wrong one.

5. **No GKE-native runner DaemonSet exists.** Daytona ships a Terraform
   module for AWS EC2 and `install.sh` for any Linux VM. The runner can be
   *deployed onto* GKE nodes via the `daytona` chart's DaemonSet — but
   that's the **full self-hosted** chart, not `daytona-region`. So even on
   GKE-native BYOC, runners end up on *separate* GCE instances, not inside
   the cluster as pods. This repro mirrors that — proxy/snapshot-manager
   run on the GKE cluster, runners run on dedicated GCE instances.

6. **The wildcard proxy URL needs DNS-01 TLS.** `proxy.example.com` and
   `*.proxy.example.com` must both have a trusted cert. HTTP-01 doesn't
   cover wildcards, so you need DNS-01, so you need an API token for your
   DNS provider.

7. **`helm uninstall` does NOT clean up Daytona Cloud state.** The region
   you registered stays in Daytona Cloud's database. Runners likewise.
   You have to call the API or visit the dashboard. The `teardown.sh`
   script in this repo handles this.

8. **No way to validate the region in isolation.** Until at least one
   runner is registered and reports "ready", `daytona.create(target=region)`
   will fail. So "did my chart install work?" can only be answered by
   completing the entire GCE step too.

## Capacity sizing

Defaults are tuned for the prod-shape capacity described in the BYOC PDF:

- **`RUNNER_COUNT=4`** × **`RUNNER_MACHINE_TYPE=n2-standard-8`**
  = 32 vCPU / 128 GiB total raw
- Reported to Daytona as `CUSTOM_CPU_COUNT=8` / `CUSTOM_MEMORY_GB=28` per
  runner (the bootstrap defaults), so the region advertises **32 vCPU /
  112 GiB** of sandbox capacity to Daytona Cloud's scheduler.
- With 2× CPU over-provisioning, that's enough for ~16 sandboxes at 4 vCPU
  / 4 GiB each — matching the 64 vCPU / 64 GiB "16 sandboxes" example.

The interactive flow in `repro.sh` queries your CPUS quota in `$GCP_REGION`
and offers a menu of machine types that fit. You can override the
non-interactive defaults via `RUNNER_COUNT` and `RUNNER_MACHINE_TYPE` env
vars, or skip the prompt entirely with `NON_INTERACTIVE=true`.

## What this reproducer requires

| Thing | Where it comes from |
|---|---|
| `DAYTONA_API_KEY` | Generate at https://app.daytona.io/dashboard/keys |
| `DOMAIN` | A subdomain you own under a Cloudflare-managed zone (e.g. `cmc.yourdomain.com`) |
| `ACME_EMAIL` | Anything — used for Let's Encrypt registration |
| `CLOUDFLARE_API_TOKEN` | https://dash.cloudflare.com/profile/api-tokens — "Edit zone DNS" template, scoped to your zone |
| `GCP_PROJECT` | Your GCP project ID (e.g. `daytona-cmc-12345`). Must have billing enabled. |
| `gcloud` auth | `gcloud auth login` AND `gcloud auth application-default login`. The principal needs Owner or a combination of: roles/container.admin, roles/compute.admin, roles/iam.serviceAccountAdmin, roles/iam.securityAdmin, roles/secretmanager.admin, roles/storage.admin, roles/serviceusage.serviceUsageAdmin. |
| CLIs installed locally | `gcloud`, `kubectl`, `helm`, `jq`, `curl`, `openssl`, `envsubst`, `shasum`, `shred` (or `gshred` from coreutils on macOS) |
| Optional: faster IAP tunnel | `pip3 install numpy` — gcloud uses NumPy for upload acceleration in `gcloud compute ssh --tunnel-through-iap`. Without it you'll see the harmless `WARNING: To increase the performance of the tunnel, consider installing NumPy` line on each SSH/bootstrap call. Phase 14 doesn't care, but installing it speeds up the bootstrap script's payload upload by ~2x. |

## How to run

```bash
cd ~/main/test/cmc/gcs-repro

export DAYTONA_API_KEY='dtn_paste-personal-key-here'
export DOMAIN='cmc.yourdomain.com'
export ACME_EMAIL='you@yourdomain.com'
export CLOUDFLARE_API_TOKEN='paste-cf-token'
export GCP_PROJECT='your-project-id'

# GCP auth - both required
gcloud auth login
gcloud auth application-default login

# First full run - everything end to end
# (~20-30 min: ~10 min GKE, ~5 min cert issuance, ~10 min runners)
./repro.sh

# Iterate by phase:
PHASE=1 ./repro.sh    # preflight + APIs + GCS + HMAC + GKE + ingress + cert-manager
PHASE=2 ./repro.sh    # also region certificates
PHASE=3 ./repro.sh    # also helm install (region registered, no runners yet)
PHASE=4 ./repro.sh    # also GCE runner provision (no bootstrap yet)
PHASE=5 ./repro.sh    # full end-to-end (default)

# Skip the interactive instance-picker (use env defaults):
NON_INTERACTIVE=true ./repro.sh

# When done:
./teardown.sh
```

### Overriding defaults

```bash
# Cheaper repro: 1 runner instead of 4
RUNNER_COUNT=1 ./repro.sh

# Different GCP region
GCP_REGION=us-east1 ./repro.sh

# Different runner SKU (suppresses the interactive picker)
RUNNER_MACHINE_TYPE=c3-standard-22 RUNNER_COUNT=2 \
  CUSTOM_CPU_COUNT=20 CUSTOM_MEMORY_GB=80 ./repro.sh

# Use LE staging while iterating (avoids prod LE rate limits)
STAGING=true ./repro.sh
```

## Layout

```
gcs-repro/
├── repro.sh                       # main provision script (15 phases)
├── teardown.sh                    # cleanup: Daytona runners + region,
│                                  # helm uninstall, GCE instances, GKE,
│                                  # GCS bucket, HMAC keys, service accounts,
│                                  # Secret Manager secrets, firewall rules,
│                                  # Cloudflare A records, local state.
├── values-region.yaml.tmpl        # daytona-region helm values (envsubst'd
│                                  # with DOMAIN, REGION_NAME, API creds,
│                                  # GCS bucket + HMAC keys; rendered to a
│                                  # mktemp file that is shred'd after helm
│                                  # install completes)
├── runner-bootstrap.sh            # runs on each runner GCE via
│                                  # `gcloud compute ssh --tunnel-through-iap`;
│                                  # presets every env var install.sh checks
│                                  # for; fetches HMAC + runner token from
│                                  # Secret Manager via the instance SA;
│                                  # runs install.sh non-interactively.
├── e2e.sh                         # SDK test: daytona.create(target=region)
│                                  # then code_run("print('Hello World')")
└── .state/                        # generated at runtime (region-id, names,
                                   # Secret Manager resource names, runner
                                   # instance names, rendered cert manifests).
                                   # No secret values — only resource refs.
```

## Validating each phase

At the end of every phase, you can spot-check:

```bash
# Phase 1 (GCS + HMAC): bucket exists, HMAC stored in Secret Manager
gcloud storage buckets describe gs://<bucket>
gcloud secrets versions list daytona-<region-name>-hmac-access

# Phase 1 (GKE): nodes Ready, ingress LB IP assigned
kubectl get nodes
kubectl -n ingress-nginx get svc ingress-nginx-controller

# Phase 2 (certs): Certificate resources Ready
kubectl -n daytona-region get certificate

# Phase 3 (helm + region): region registered in Daytona Cloud
curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" \
  https://app.daytona.io/api/regions | jq '.[] | {name, id, proxyUrl}'

# Phase 4 (runners): GCE instances running, OS Login + SA configured
gcloud compute instances list \
  --filter="labels.daytona-region=<region-name>" \
  --format="table(name,zone,machineType.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)"

# Phase 5 (registered + e2e): runners report 'ready' in Daytona Cloud
curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" \
  https://app.daytona.io/api/runners | jq '.[] | {id, name, state, score:.availabilityScore}'

# Inspect any one runner's systemd unit (verifies declarative builder env)
gcloud compute ssh <runner-instance-name> --tunnel-through-iap --zone <zone>
sudo grep -E '^Environment=' /etc/systemd/system/daytona-runner.service
```

## Comparison to the AWS reproducer (`../aws-repro/`)

| | GCP (this) | AWS (`../aws-repro/`) |
|---|---|---|
| Cluster | GKE Standard via gcloud | EKS via eksctl |
| Compute | GCE (n2-standard-8 × N) via `gcloud compute instances create` | EC2 (m7i.2xlarge × N) via `aws ec2 run-instances` |
| Bootstrap channel | `gcloud compute ssh --tunnel-through-iap` | SSM Run Command |
| Snapshot storage | GCS interop XML API | Native S3 (no shim) |
| Storage credentials | HMAC keys on a dedicated GSA | Static IAM user access keys |
| Secret store | Google Secret Manager | none (state files only) |
| Builder endpoint | `https://storage.googleapis.com` | `https://s3.<region>.amazonaws.com` |
| LB | GCE Network LB (via ingress-nginx default) | NLB (via ingress-nginx annotation) |
| DNS records | A records (LB has an IP) | CNAME (NLB has a hostname) |
| Cluster cost | ~$0.10/hr GKE + ~$0.40/hr × N runners | ~$0.10/hr EKS + ~$0.40/hr × N runners |

The GCP path is *more secure by default* than AWS because:
- Secret Manager handles all cross-machine secrets (vs raw env vars baked
  into AWS SSM payloads)
- IAP-tunneled SSH means no public SSH port on runners
- HMAC keys are per-service-account, scoped to a single bucket

The GCP path is *slightly more involved* than AWS because:
- HMAC keys are not first-class GCP IAM principals — you need a dedicated
  service account that the HMAC keys are minted against
- GKE doesn't ship with `kubernetes.io/role/elb`-tagged subnets like EKS,
  so the runner-VPC discovery is different (always use the cluster's
  network/subnetwork directly)
- Quota for both vCPUs and `IN_USE_ADDRESSES` matters; GCP enforces them
  more visibly than AWS

## GCS-specific quirks that this repro handles

- **No Uniform Bucket-Level Access (UBLA).** GCS UBLA rejects any request
  bearing an `x-amz-acl` header with HTTP 400 InvalidArgument. Daytona's
  snapshot-manager (built on `docker/distribution` v2 with the S3 storage
  driver) always sends `x-amz-acl: private` when initiating a multipart
  upload. So if UBLA is enabled, every `docker push` of a layer larger
  than ~5 MB (which is most layers) fails. The script deliberately
  creates the bucket WITHOUT `--uniform-bucket-level-access`. PAP
  (public-access prevention) stays on — it only blocks PUBLIC ACLs, not
  the private one the snapshot-manager sends, so it's compatible.
- **HMAC interop credentials, not IAM.** GCS exposes an S3-compatible
  endpoint at `storage.googleapis.com` that uses HMAC keys (minted per
  service account). The chart's snapshot-manager and every runner's
  `AWS_*` env vars all point at the SAME HMAC keys + bucket, giving us
  the bidirectional read/write the declarative-builder pipeline needs.
- **Bucket region matters.** GCS bucket location must equal the
  `SNAPSHOT_MANAGER_STORAGE_S3_REGION` the chart sends in S3 signature
  headers. The script enforces this by setting both to `$GCP_REGION`.

## Known gaps in this reproducer

- **No Workload Identity / Workload Identity Federation path.** The
  snapshot-manager pod uses HMAC keys (static credentials) via Secret
  Manager. Production should use Workload Identity to bind the
  snapshot-manager ServiceAccount to a GSA with `storage.objectAdmin`
  on the bucket. The chart supports this — see the README's "S3
  Authentication" section. We chose HMAC here because (a) the runner
  binary uses an S3 client and needs HMAC-shaped credentials anyway,
  (b) it's the closest thing to the AWS repro for direct comparison.
- **No MIG/autoscaler for runners.** Just N raw GCE instances. Real fleets
  want a managed instance group with a template so a dead runner respawns
  automatically.
- **Default network.** Runners + GKE land in the project's `default` VPC.
  Production would use a dedicated VPC with private subnets and Cloud NAT.
- **Single zone for runners.** All runners land in the first zone of
  `$GCP_REGION`. Real fleets want runners spread across multiple zones.
- **`e2e.sh` does not yet test private-GAR pulls.** Stage A pulls a
  public image; Stage B uses the declarative builder. A "Stage C" that
  drives an end-to-end private-GAR snapshot through Daytona's broker
  is not yet ported from the AWS repro. Use `gcr-setup.sh` + the
  Daytona dashboard to test manually for now.

## Optional: private Artifact Registry for Daytona Cloud

If you want a sandbox in your BYOC region to pull a private image from
your own GCP Artifact Registry (the GCP equivalent of AWS ECR), use
`gcr-setup.sh`. It provisions an Artifact Registry repository in
`$GCP_REGION`, a dedicated minimal-privilege service account
(`roles/artifactregistry.reader` scoped to that one repo), and a JSON
key. The key is stored in Google Secret Manager and printed on stdout
once so you can paste it into Daytona's dashboard registry form.

```bash
# After repro.sh has run successfully:
export GCP_PROJECT='your-project'
export GCP_REGION='us-east1'   # or whatever you used for repro.sh
./gcr-setup.sh
```

You'll get output like:

```
============================================================
  DAYTONA REGISTRY CONFIGURATION
============================================================
  Paste these into https://app.daytona.io/dashboard/registries → 'Add Registry'

  Registry URL    : us-east1-docker.pkg.dev
  Project ID      : your-project
  Username        : _json_key
  Password / Key  : (the entire JSON below, including braces)

  Image references in sandboxes use the form:
      us-east1-docker.pkg.dev/your-project/daytona-images/<image>:<tag>

  Push a test image (one-time, on your workstation):
      gcloud auth configure-docker us-east1-docker.pkg.dev --quiet
      docker pull alpine:3.21
      docker tag alpine:3.21 us-east1-docker.pkg.dev/your-project/daytona-images/test-alpine:latest
      docker push us-east1-docker.pkg.dev/your-project/daytona-images/test-alpine:latest

------ JSON KEY BEGIN ------
{...the actual JSON service-account key...}
------ JSON KEY END --------
```

Re-print the key any time without rotating:

```bash
./gcr-setup.sh --show-key
```

Rotate the key (deletes the old one in IAM, mints a new one, stores in
Secret Manager, prints once):

```bash
./gcr-setup.sh --rotate-key
```

Standalone teardown (or just run `./teardown.sh` — it picks up GAR via
labels and naming convention automatically):

```bash
./gcr-setup.sh --teardown
```

## When you've finished running it

You will have:
1. A working BYOC region on GKE + 4 runners on dedicated GCE instances
2. Working SDK calls targeting your custom region
3. Working declarative builder snapshot creation (the runner's `AWS_*`
   env vars point at the same GCS bucket the snapshot-manager uses)
4. Direct experience with the 8 pain points listed above

You can then either tear down (cheapest), keep it running to demo
(~$1.70/hr for the prod-shape config), or iterate by running individual
phases as you experiment.

## Manual cleanup that teardown.sh CANNOT do

`teardown.sh` cleans up all GCP and Cloudflare resources programmatically
and deletes the region + runners from Daytona Cloud via the API. Two
things cannot be automated and require a click in
[app.daytona.io](https://app.daytona.io):

1. **The user/organization that owns the region.** Removing this is a
   privileged dashboard action — there's no API.
2. **Personal API keys.** Rotate or revoke at
   https://app.daytona.io/dashboard/keys after each test run if you want
   to be extra safe.

The script will print explicit reminders at the end of `teardown.sh`.
