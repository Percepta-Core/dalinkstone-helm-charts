# Daytona BYOC on AWS — Customer Journey Reproducer

This reproducer walks through what a real Daytona Cloud customer experiences
when adopting **Customer Managed Compute (BYOC)** on AWS. The goal is to make
the friction points concrete, not just to ship working scripts.

## What BYOC actually is

A BYOC customer uses **Daytona Cloud** (`app.daytona.io`) as their control
plane but runs the underlying **compute** in their own AWS account. They do
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
                  │       target="my-eks-region")    │
                  │                                  │
                  ▼                                  ▼
   ┌──────────────────────────┐         ┌─────────────────────────┐
   │  Your EKS cluster        │         │  Your runner EC2 instances│
   │  (proxy + snapshot-mgr)  │         │  (4 × m7i.2xlarge)        │
   │  - daytona-region chart  │◄────────┤  - daytona-runner systemd │
   │    - proxy               │  HTTPS  │  - Docker + sysbox        │
   │    - snapshot-manager    │         │  - sandbox containers     │
   │  - ingress-nginx (NLB)   │         │    run HERE               │
   │  - cert-manager          │         │                           │
   └──────────────────────────┘         └─────────────────────────┘
                  │                                  │
                  └───────────────┬──────────────────┘
                                  ▼
                       ┌────────────────────┐
                       │  S3 bucket (yours) │
                       │  - snapshot blobs  │
                       │  - builder context │
                       └────────────────────┘
```

Daytona Cloud routes the customer's SDK calls (or dashboard actions) through
the customer's proxy (running in EKS), which forwards them to one of the
customer's runner EC2 instances, which runs the actual sandbox container
locally. The snapshot-manager (in EKS) and every runner (on EC2) read and
write the same customer-owned S3 bucket.

## The 15 steps a real customer goes through

In practice — even with this reproducer automating most of it — these are the
actual decisions and actions involved.

| # | Step | Automated by this repro? |
|---|---|---|
| 1 | Sign up at daytona.io | ❌ Interactive web flow |
| 2 | Create an organization | ❌ Dashboard click |
| 3 | Generate a personal API key at `app.daytona.io/dashboard/keys` | ❌ Manual; the BYOC docs don't link to this page |
| 4 | Pick a region name (lowercase, alphanumeric + `.-_`) | ✅ Auto-generated `eks-cmc-<timestamp>` |
| 5 | Pick a proxy URL (FQDN you own) | ❌ You provide `DOMAIN` |
| 6 | Set up S3 bucket + IAM user for snapshots and the declarative builder | ✅ `aws s3api create-bucket` + IAM user with R/W policy |
| 7 | Provision the EKS cluster | ✅ `eksctl create cluster` (creates VPC, node group, addons) |
| 8 | Point DNS at the cluster's NLB | ✅ Cloudflare API CNAMEs |
| 9 | Install ingress-nginx (NLB-backed) | ✅ helm |
| 10 | Install cert-manager + ClusterIssuer for wildcard TLS | ✅ DNS-01 against Cloudflare |
| 11 | Install `daytona-region` chart (registers region, brings up proxy + snapshot-manager) | ✅ helm install |
| 12 | Realize the chart didn't deploy runners | ✅ This README + script tell you |
| 13 | Provision runner EC2 instances | ✅ `aws ec2 run-instances` × `RUNNER_COUNT` |
| 14 | Bootstrap each runner: install Docker + sysbox + daytona-runner; register via `/api/runners` | ✅ `aws ssm send-command` + bootstrap script (with `AWS_*` env vars for the declarative builder S3) |
| 15 | Validate with the SDK | ✅ `e2e.sh` runs `daytona.create(target=<region>)` |

## Pain points worth seeing for yourself

This is what makes BYOC harder than the marketing suggests. Each one is real,
and each surfaces during this repro.

1. **The `daytona-region` chart name implies it includes runners. It does not.**
   This is the most common BYOC stumble. The chart deploys proxy +
   snapshot-manager only. The chart install succeeds, the region appears in
   the dashboard, and then `daytona.create(target=region)` fails with "no
   available runners" until you do the EC2 step.

2. **The declarative builder needs S3 wired up in two places, not one.** The
   snapshot-manager (in EKS) gets its credentials from
   `services.snapshotManager.storage.s3.*` in helm values. Every runner EC2
   instance ALSO needs `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/
   `AWS_DEFAULT_BUCKET`/`AWS_REGION` env vars in
   `/etc/systemd/system/daytona-runner.service`. They must point at the same
   bucket. If they don't, snapshot creation via `Image.debian_slim(...).pip_install(...)`
   fails with an S3 access error at the inspect/build step.

3. **Two different `dtn_xxx` API keys.** The *customer/org* key is used by
   the chart to register the region. The *runner* key is returned when you
   register a runner. The CLI/`install.sh` prompts for "Admin API Key" which
   means the customer key — the runner key is then generated and stored in
   `/etc/daytona/runner.env`. They look identical (`dtn_...`) so it's easy
   to use the wrong one.

4. **No EKS-native runner DaemonSet exists.** Daytona ships a Terraform
   module for AWS EC2 and `install.sh` for any Linux VM. The runner can be
   *deployed onto* EKS nodes via the `daytona` chart's DaemonSet — but
   that's the **full self-hosted** chart, not `daytona-region`. So even on
   EKS-native BYOC, runners end up on *separate* EC2 instances, not inside
   the cluster as pods. This repro mirrors that — proxy/snapshot-manager run
   on the EKS cluster, runners run on dedicated m7i.2xlarge EC2 instances.

5. **The wildcard proxy URL needs DNS-01 TLS.** `proxy.example.com` and
   `*.proxy.example.com` must both have a trusted cert. HTTP-01 doesn't
   cover wildcards, so you need DNS-01, so you need an API token for your
   DNS provider.

6. **`helm uninstall` does NOT clean up Daytona Cloud state.** The region
   you registered stays in Daytona Cloud's database. Runners likewise. You
   have to call the API or visit the dashboard. The `teardown.sh` script in
   this repo handles this.

7. **No way to validate the region in isolation.** Until at least one
   runner is registered and reports "ready", `daytona.create(target=region)`
   will fail. So "did my chart install work?" can only be answered by
   completing the entire EC2 step too.

8. **Cluster name length matters.** EKS-via-CloudFormation has a 38-char
   limit on stack names. The repro hashes `$DOMAIN` to derive a stable,
   short cluster name suffix — and re-runs against the same `$DOMAIN` hit
   the same cluster.

## Capacity sizing

Defaults are tuned for the prod-shape capacity described in the BYOC PDF:

- **`RUNNER_COUNT=4`** × **`RUNNER_INSTANCE_TYPE=m7i.2xlarge`**
  = 32 vCPU / 128 GiB total raw
- Reported to Daytona as `CUSTOM_CPU_COUNT=8` / `CUSTOM_MEMORY_GB=28` per
  runner (the bootstrap defaults), so the region advertises **32 vCPU / 112 GiB**
  of sandbox capacity to Daytona Cloud's scheduler.
- With 2× CPU over-provisioning, that's enough for ~16 sandboxes at 4 vCPU
  / 4 GiB each — matching the 64 vCPU / 64 GiB "16 sandboxes" example.

Override via env vars for a smaller repro (e.g. `RUNNER_COUNT=1` for ~$0.50/hr).

## What this reproducer requires

| Thing | Where it comes from |
|---|---|
| `DAYTONA_API_KEY` | Generate at https://app.daytona.io/dashboard/keys |
| `DOMAIN` | A subdomain you own under a Cloudflare-managed zone (e.g. `cmc.yourdomain.com`) |
| `ACME_EMAIL` | Anything — used for Let's Encrypt registration |
| `CLOUDFLARE_API_TOKEN` | https://dash.cloudflare.com/profile/api-tokens — "Edit zone DNS" template, scoped to your zone |
| AWS account | Configured `aws` CLI (profile, env keys, or SSO). Must have IAM permissions for IAM, EKS, EC2, VPC, S3, ELB, SSM, CloudFormation |
| CLIs installed locally | `aws`, `eksctl`, `kubectl`, `helm`, `jq`, `curl`, `openssl`, `envsubst`, `shasum` |

## How to run

```bash
cd scripts/aws-setup/test

export DAYTONA_API_KEY='dtn_paste-personal-key-here'
export DOMAIN='cmc.yourdomain.com'
export ACME_EMAIL='you@yourdomain.com'
export CLOUDFLARE_API_TOKEN='paste-cf-token'

# AWS auth - any one of these
export AWS_PROFILE=my-profile
# OR
# export AWS_ACCESS_KEY_ID='...'
# export AWS_SECRET_ACCESS_KEY='...'
# OR
# aws sso login

# First full run - everything end to end
# (~25-35 min: ~15 min EKS, ~5 min cert issuance, ~10 min runners)
./repro.sh

# Iterate by phase:
PHASE=1 ./repro.sh    # preflight + S3 + IAM + EKS + ingress + cert-manager
PHASE=2 ./repro.sh    # also region certificates
PHASE=3 ./repro.sh    # also helm install (region registered, no runners yet)
PHASE=4 ./repro.sh    # also EC2 runner provision (no bootstrap yet)
PHASE=5 ./repro.sh    # full end-to-end (default)

# When done:
./teardown.sh
```

### Overriding defaults

```bash
# Cheaper repro: 1 runner instead of 4
RUNNER_COUNT=1 ./repro.sh

# Different AWS region
AWS_DEFAULT_REGION=eu-west-1 ./repro.sh

# Smaller runner instance (for cost testing — note this changes the sandbox
# capacity advertised to Daytona)
RUNNER_INSTANCE_TYPE=m7i.large CUSTOM_CPU_COUNT=2 CUSTOM_MEMORY_GB=6 ./repro.sh

# Use LE staging while iterating (avoids prod LE rate limits)
STAGING=true ./repro.sh
```

## Layout

```
aws-repro/
├── repro.sh                       # main provision script (15 phases)
├── teardown.sh                    # cleanup: Daytona runners + region,
│                                  # helm uninstall, EC2, eksctl delete,
│                                  # S3 empty+delete, IAM user+role,
│                                  # Cloudflare CNAMEs, local state.
├── values-region.yaml.tmpl        # daytona-region helm values (envsubst'd
│                                  # with DOMAIN, REGION_NAME, API creds,
│                                  # S3 bucket + IAM keys)
├── runner-bootstrap.sh            # runs on each runner EC2 via aws ssm
│                                  # send-command; presets every env var
│                                  # install.sh checks for, then runs
│                                  # install.sh non-interactively. Includes
│                                  # AWS_* env vars for declarative builder.
├── e2e.sh                         # SDK test: daytona.create(target=region)
│                                  # then code_run("print('Hello World')")
└── .state/                        # generated at runtime (region-id, names,
                                   # IAM keys, runner instance IDs, rendered
                                   # manifests). gitignore this.
```

## Validating each phase

At the end of every phase, you can spot-check:

```bash
# Phase 1 (preflight + S3 + IAM): bucket and user exist
aws s3 ls s3://<bucket>
aws iam get-user --user-name <region>-s3

# Phase 1 (EKS): nodes Ready, ingress LB hostname assigned
kubectl get nodes
kubectl -n ingress-nginx get svc ingress-nginx-controller

# Phase 2 (certs): Certificate resources Ready
kubectl -n daytona-region get certificate

# Phase 3 (helm + region): region registered in Daytona Cloud
curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" \
  https://app.daytona.io/api/regions | jq '.[] | {name, id, proxyUrl}'

# Phase 4 (runners): EC2 instances running, SSM-managed
aws ec2 describe-instances \
  --filters "Name=tag:daytona:region,Values=<region-name>" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress]' --output table

aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=<instance-id-1>,<instance-id-2>,..." \
  --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output table

# Phase 5 (registered + e2e): runners report 'ready' in Daytona Cloud
curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" \
  https://app.daytona.io/api/runners | jq '.[] | {id, name, state, score:.availabilityScore}'

# Inspect any one runner's systemd unit (verifies declarative builder env)
aws ssm start-session --target <instance-id>
sudo grep -E '^Environment=' /etc/systemd/system/daytona-runner.service
```

## Comparison to the Azure reproducer (`../azure-repro/`)

| | AWS (this) | Azure (`../azure-repro/`) |
|---|---|---|
| Cluster | EKS via eksctl | AKS via `az aks create` |
| Compute | EC2 (m7i.2xlarge × N) via `aws ec2 run-instances` | VM (Standard_D4s_v3 × 1) via `az vm create` |
| Bootstrap channel | SSM Run Command | `az vm run-command invoke` |
| Snapshot storage | Native S3 (no shim) | Azure Blob via rclone S3 gateway sidecar |
| Builder S3 endpoint | `https://s3.<region>.amazonaws.com` | `http://rclone-s3-gateway.daytona-region:8080` |
| LB | NLB (via ingress-nginx annotation) | Azure LB (via ingress-nginx default) |
| DNS records | CNAME (NLB has a hostname) | A (LB has an IP) |
| Cluster cost | ~$0.10/hr EKS + ~$0.40/hr × N runners | ~$0.10/hr AKS + ~$0.20/hr runner |

The AWS path is *simpler* than Azure because:
- S3 is native — no rclone shim needed
- SSM means no SSH key management
- IAM identity model is closer to what Daytona's docs assume

The AWS path is *more involved* than Azure because:
- EKS creates more underlying resources (VPC, subnets, NAT GW, IGW, route
  tables, SGs, IAM roles for the cluster, OIDC provider)
- More IAM resources to track + tear down

## Known gaps in this reproducer

- **No IRSA / instance-profile S3 path.** Uses static IAM user keys for
  both snapshot-manager and runners. Production should annotate the
  snapshot-manager ServiceAccount with an IRSA role ARN and use an EC2
  instance profile (with the same S3 policy attached) for the runners.
  The chart supports this — see `charts/daytona-region/README.md`.
- **No ASG for runners.** Just N raw EC2 instances. Real fleets want an ASG
  with a launch template so a dead runner respawns automatically.
- **No private subnets.** Runners get public IPs in EKS public subnets. The
  proxy reaches them via the VPC route table (so traffic doesn't traverse
  the internet), but the runner SG and routing surface is more permissive
  than a prod deployment would want.
- **Single AZ for runners.** All runners land in the first eksctl-created
  public subnet. Real fleets want runners spread across multiple AZs.

## When you've finished running it

You will have:
1. A working BYOC region on EKS + 4 runners on dedicated EC2 instances
2. Working SDK calls targeting your custom region
3. Working declarative builder snapshot creation (the original pain point —
   the runner's `AWS_*` env vars now point at the same S3 bucket the
   snapshot-manager uses)
4. Direct experience with the 8 pain points listed above

You can then either tear down (cheapest), keep it running to demo
(~$1.70/hr for the prod-shape config), or iterate by running individual
phases as you experiment.
