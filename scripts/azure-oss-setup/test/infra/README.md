# Azure OSS infra tests

Live-cluster regression tests for the self-hosted OSS Daytona deployment on
Azure AKS. These tests assert behaviors that the static chart-render checks
under `scripts/_lib/check/` cannot prove: that the api actually bootstrapped a
runner, that cert-manager actually issued a real cert, that node recycling
actually converges, etc.

## Prerequisites

- `kubectl` context pointing at the running AKS cluster
- `az` logged in to the subscription that owns the AKS cluster
- `scripts/azure-oss-setup/.state/prompts.env` and `oss-secrets.env` present
  (created by `up.sh` on first install)
- Helm install fully complete (`bash scripts/azure-oss-setup/up.sh`)

All three scripts source `scripts/_lib/common.sh` and `scripts/_lib/infra-test.sh`,
which provide the shared `omc::infra::*` helpers (postgres queries, cert probes,
AKS node lifecycle, etc.).

## Scripts

### `diagnose.sh` — pure information, never fails

```bash
bash scripts/azure-oss-setup/test/infra/diagnose.sh
```

Prints an 8-step health snapshot of the live cluster:

1. Pod states (all components, with node placement)
2. Sandbox node listing (label `daytona-sandbox-c=true`)
3. api pod's `DEFAULT_RUNNER_*` / `RUNNER_MANAGER_API_KEY` env values
4. runner pod's `API_TOKEN` / `SERVER_URL` / `NODE_NAME` env values
5. `runner` table contents (uses upstream-correct column names — `memoryGiB`,
   `diskGiB`, `apiVersion`, etc.)
6. `region` table contents (`SELECT * FROM region` so schema variations don't
   break the query)
7. Token wiring assertion (api `DEFAULT_RUNNER_API_KEY` must equal runner
   `API_TOKEN`)
8. TLS cert issuer for `${BASE_DOMAIN}` — distinguishes Let's Encrypt vs the
   nginx-ingress fake cert

Plus the most recent log lines from runner-manager and the runner binary.

Use this when something looks wrong; the output tells you which assertion in
`fresh-install-validate.sh` would fail.

### `fresh-install-validate.sh` — assertion gate

```bash
bash scripts/azure-oss-setup/test/infra/fresh-install-validate.sh
```

Hard-fails if the cluster is not ready for sandbox creation. Asserts:

- Every core component pod is Ready (api, proxy, runner, runnermanager, postgres)
- At least one sandbox node exists with the right label
- api's `DEFAULT_RUNNER_API_KEY` matches the runner pod's `API_TOKEN`
- DB has at least one runner with `state='ready'` in `region='us'`
- If a cert-manager `Certificate` resource exists, it is `Ready=True`
- The TLS cert served by `${BASE_DOMAIN}:443` is NOT the nginx fake cert

Run this immediately after `bash up.sh` completes. Exit code 0 means you can
safely run the sandbox smoke tests in `test/test_sandbox.py`.

### `recycle-node.sh` — node lifecycle regression

```bash
# Recycle the first sandbox node (default)
bash scripts/azure-oss-setup/test/infra/recycle-node.sh

# Recycle a specific node
NODE_TO_RECYCLE=aks-sandbox-12345678-vmss000000 \
  bash scripts/azure-oss-setup/test/infra/recycle-node.sh
```

Asserts the chart's recovery flow:

1. Capture baseline (current sandbox nodes + READY runner count)
2. Drain + `az aks nodepool delete-machines` on the target node
3. Wait for AKS to provision a replacement node (10 min budget)
4. Wait for the new node to reach Kubernetes `Ready` (5 min)
5. Wait for the runner DaemonSet to schedule a pod on the new node (3 min)
6. Wait for that pod to reach `Ready` (10 min — docker-installer + sysbox
   provisioning is the slow path on first boot)
7. Wait for the api DB to see a runner with `state='ready'` in the region (5 min)
8. Confirm READY runner count did not regress

If any wait expires, prints the runner-table state and exits non-zero so the
operator can `bash diagnose.sh` for context.

## Failure interpretation

| Failure | Most likely cause | Fix |
|---|---|---|
| `runner pod Ready` times out | Docker / Sysbox install on host failed (XFS+Sysbox+AKS24.04 known issue) | `kubectl logs <runner-pod> -c docker-installer`; consider switching docker storage off XFS loopback |
| `no READY runner in DB` | api bootstrap skipped (`DEFAULT_RUNNER_NAME` empty) | `helm upgrade` to pick up chart fix; confirm `kubectl exec deploy/daytona-api -- env \| grep DEFAULT_RUNNER_NAME` |
| `token mismatch` | api/runner not running same chart version | `helm upgrade` with the latest chart; both deployments restart |
| `TLS cert is fake` | cert-manager challenge failed (HTTP-01 can't satisfy wildcards) | Re-run `up.sh` with `CLOUDFLARE_API_TOKEN` for DNS-01 issuer |
| `Certificate not Ready` | DNS-01 challenge in flight or Cloudflare API token rejected | `kubectl -n daytona describe certificate <name>` — look at the Events |
| `runner state=initializing` for >2 min | Runner binary not heartbeating | Check `kubectl logs <runner-pod> -c runner` for connectivity/TLS errors |
| `availabilityScore=0` on a READY runner | Runner reported zero capacity (Docker not actually working on host) | `kubectl logs <runner-pod> -c docker-installer`; verify dockerd running on the node |

## CI integration (future work)

These scripts are designed to be runnable individually OR composed into a CI
workflow that does fresh install → validate → recycle → validate → teardown.
They use absolute paths via `$REPO_ROOT` so they work from any cwd, and they
exit with proper codes for `set -e` callers.

## What these tests do NOT cover

- Multi-region scheduling (single region only — matches the OSS chart shape)
- Sandbox-creation end-to-end (use `python test_sandbox.py` in this directory's
  parent for that)
- Disaster scenarios (postgres pod loss, etcd corruption) — out of scope for
  the OSS deployment's blast radius
- Cross-cloud (only Azure AKS — the BYOC `scripts/{aws,azure,gcs}-setup/test/`
  trees cover those)
