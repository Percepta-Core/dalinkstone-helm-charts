# Cloud QA Runbook — Prompt 1 BYOC foundation

> **Purpose:** Operator-driven gate. The agent produces the exact commands; the operator runs them against a real EKS / AKS / GKE cluster and captures the output into `test/baselines/cloud-qa-evidence.md`. Both reviewer (`code-reviewer`) and verifier (`verifier`) must see operator-captured cloud evidence before this PR is marked complete.

## Prerequisites (operator-side)

- A worker-pool node labeled `daytona-sandbox-c=true` and tainted `sandbox=true:NoSchedule` (the chart's runner DaemonSet pins to those labels).
- Operator has a cluster admin kubeconfig set in `$KUBECONFIG`.
- Operator has a runner image reachable from cluster nodes — either the public `docker.io/daytonaio/daytona-runner:v0.167.0` or a private mirror.

## Primary gate — EKS (S4 IRSA proof)

This is the canonical cloud QA for Scenario S4. Required.

### 0. Pre-flight

```bash
# Confirm cluster is EKS with OIDC enabled
aws eks describe-cluster --name "$CLUSTER" \
  --query 'cluster.identity.oidc.issuer' --output text

# Create a real IAM role with the trust policy matching the cluster OIDC + the runner SA
# (operator-side; see docs/upstream-issues/runner-irsa-support.md trust policy template)
export ROLE_ARN="arn:aws:iam::<ACCOUNT_ID>:role/daytona-runner-byoc"
```

### 1. Install

```bash
helm dep build ./charts/daytona-region

helm install daytona-region ./charts/daytona-region \
  -n daytona --create-namespace \
  -f test/fixtures/region-aws-irsa.values.yaml \
  --set "services.runner.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${ROLE_ARN}" \
  --set "services.runner.image.tag=v0.167.0" \
  --wait --timeout 5m
```

### 2. Rollout + describe

```bash
kubectl -n daytona rollout status daemonset/daytona-region-runner --timeout=5m
kubectl -n daytona describe pod -l app.kubernetes.io/component=runner
kubectl -n daytona get ds,po,svc,sa -l app.kubernetes.io/component=runner
```

### 3. S4 — IRSA env injection check

```bash
RUNNER_POD=$(kubectl -n daytona get pod -l app.kubernetes.io/component=runner -o jsonpath='{.items[0].metadata.name}')

# IRSA-injected env vars from the pod-identity-webhook (NOT from values)
kubectl -n daytona exec "$RUNNER_POD" -c runner -- env | grep -E '^AWS_(WEB_IDENTITY|ROLE_ARN|STS_REGIONAL|REGION)'

# Confirm AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY are ABSENT (irsa mode, shim=false)
kubectl -n daytona exec "$RUNNER_POD" -c runner -- sh -c 'env | grep -E "AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)" || echo "ABSENT (expected)"'

# Confirm AWS_REGION + AWS_DEFAULT_BUCKET + AWS_ENDPOINT_URL still emit
kubectl -n daytona exec "$RUNNER_POD" -c runner -- sh -c 'env | grep -E "AWS_(REGION|DEFAULT_BUCKET|ENDPOINT_URL)"'

# IRSA caller-identity proof — should return the role-arn from the SA annotation
kubectl -n daytona exec "$RUNNER_POD" -c runner -- sh -c 'aws sts get-caller-identity 2>&1 || echo "NO_AWS_CLI (acceptable; check CloudTrail AssumeRoleWithWebIdentity event instead)"'
```

**Expected output:**
- `AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token`
- `AWS_ROLE_ARN=arn:aws:iam::<ACCOUNT_ID>:role/daytona-runner-byoc`
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` ABSENT
- `aws sts get-caller-identity` returns `Arn: arn:aws:sts::<ACCOUNT_ID>:assumed-role/daytona-runner-byoc/<session>`

### 4. S2 — runner main container shape

```bash
kubectl -n daytona get pod "$RUNNER_POD" \
  -o jsonpath='{.spec.containers[?(@.name=="runner")]}{"\n"}' | jq '{name, image, securityContext, ports, envFrom, volumeMounts}'
```

**Expected:** privileged=true, ports `api 3000/3000` + `ssh 2220/2220`, envFrom has runner-config + runner-secrets + region-config (optional), volumeMounts has `var-lib-daytona /var/lib/daytona` and `runner-docker-daemon-config /etc/docker/daemon.json`.

### 5. S3 — dynamic host alias proof

```bash
# Confirm the docker-installer sidecar resolved snapshot-manager via getent and wrote it to /etc/hosts on the host
kubectl -n daytona logs "$RUNNER_POD" -c docker-installer | grep -E 'add_host_alias|host-alias'

# Confirm the host /etc/hosts has the entry (via nsenter from the docker-installer)
kubectl -n daytona exec "$RUNNER_POD" -c docker-installer -- \
  nsenter -t 1 -m -u -n -i grep snapshot-manager /etc/hosts || echo "no entry (snapshot-manager not in DNS yet — expected during initial install)"
```

## Secondary gate — AKS (S2 + S3 + AKS tarball fallback)

This validates non-EKS distros and the d1892ef AKS tarball fallback.

```bash
helm install daytona-region ./charts/daytona-region \
  -n daytona --create-namespace \
  -f test/fixtures/region-baseline.values.yaml \
  --set "services.runner.mainContainer.enabled=true" \
  --set "services.runner.image.tag=v0.167.0" \
  --set "services.runner.dockerInstaller.dynamicHostAliases={snapshot-manager}" \
  --wait --timeout 5m

# Confirm AKS tarball fallback fired
kubectl -n daytona logs daemonset/daytona-region-runner -c docker-installer | grep -E 'static.*tarball|dockerd not installed by deb'

# Confirm runner DaemonSet is up
kubectl -n daytona rollout status daemonset/daytona-region-runner --timeout=10m

# Confirm /etc/hosts on the host has snapshot-manager (or warning that it's not in DNS)
kubectl -n daytona exec daemonset/daytona-region-runner -c docker-installer -- \
  nsenter -t 1 -m -u -n -i grep snapshot-manager /etc/hosts || echo "no entry"
```

**Expected:**
- `static-tarball` install path log line appears (AKS-only)
- DaemonSet pods reach `Ready`
- runner main container starts (verify with `kubectl describe`)

## Known operational risks — capture in cloud-qa-evidence.md

### R1 — `getent hosts` cold-start on fresh nodes (S3)

`services.runner.dockerInstaller.dynamicHostAliases` is resolved by the `docker-installer` sidecar using `getent hosts <name>` from inside the pod's network namespace. On a freshly-provisioned cluster node, CoreDNS may not yet be Ready when the runner DaemonSet pod scheduler fires. In that case `getent hosts` returns empty, the alias is silently skipped with a WARN log line, and the host `/etc/hosts` is not updated for that hostname.

This is best-effort by design. The chart will re-add the alias on the next DaemonSet pod restart (rolling-update, node drain, or manual `kubectl delete pod`). For the cold-start case, the operator should:

```bash
# Confirm CoreDNS is Ready before relying on dynamicHostAliases on a fresh cluster
kubectl -n kube-system rollout status deployment/coredns --timeout=2m

# After CoreDNS Ready, restart the runner DaemonSet so the docker-installer re-runs
kubectl -n daytona rollout restart daemonset/daytona-region-runner
```

### R2 — `credentialMode: irsa` runtime gap (S4)

The chart correctly omits `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` when `services.runner.aws.credentialMode: irsa` and `allowEmptyStaticKeyShim: false`. However, the upstream `daytona-runner` binary's S3 client uses `credentials.NewStaticV4(...)` and hard-requires non-empty static keys at startup. With shim disabled, the runner pod exits immediately. With shim enabled, the runner gets past startup but cannot actually authenticate to S3 at runtime because the runner code never consults the IRSA web-identity token.

This is a known upstream limitation documented in [`docs/upstream-issues/runner-irsa-support.md`](../../docs/upstream-issues/runner-irsa-support.md). Until upstream lands the default-credential-chain support, the only production-functional credentialMode is `static`. Operators should:

```bash
# For Prompt 1 cloud QA, validate the chart correctly OMITS the static keys
# under credentialMode=irsa, EVEN THOUGH the resulting pod will fail at runtime.
# The chart-side gate is what we're testing; the runtime fix is upstream-pending.
kubectl -n daytona logs daemonset/daytona-region-runner -c runner --tail=50 | grep -E 'credentials|AWS' || true

# For production deployment, use credentialMode=static OR wait for the upstream fix.
```

## Tertiary gate — GKE (deferred to Prompt 2)

GKE Workload Identity differs structurally from EKS IRSA. The chart's `credentialMode: irsa` knob does not yet emit GKE annotations (`iam.gke.io/gcp-service-account`). Track in Prompt 2.

## Cleanup

```bash
helm uninstall daytona-region -n daytona
kubectl delete namespace daytona
```

## Operator capture instructions

For EVERY scenario above:
1. Run the command.
2. Paste the command + the actual output into `test/baselines/cloud-qa-evidence.md` under a heading matching the scenario.
3. Mark the scenario `[PASS]` or `[FAIL]` based on the expected-output match.
4. If FAIL, do NOT continue — escalate to chart maintainers with the captured output.

The PR cannot merge until both EKS S4 and AKS S2+S3 lines are PASS in `cloud-qa-evidence.md`.
