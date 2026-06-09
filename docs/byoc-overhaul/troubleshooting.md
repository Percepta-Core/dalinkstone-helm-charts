# Daytona BYOC test — Troubleshooting

Cross-cloud failure modes encountered during Prompt 1 testing, plus the DNS-01 wildcard TLS upgrade path. Most issues are operational (DNS, LB, certs) rather than chart bugs; the chart's own behavior is already validated by `helm-unittest` (16/16 pass) and `helm lint`.

## Ubuntu version mismatch — `omc::verify_node_ubuntu` aborts

If `up.sh` fails with `Refusing to continue. Ubuntu 24.04 is REQUIRED with NO EXCEPTIONS.`:

```bash
# See what your nodes actually report
kubectl get nodes -l daytona-sandbox-c=true \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.osImage}{"\n"}{end}'
```

Common causes:

- **Your cloud CLI is too old.** eksctl pre-0.200 doesn't know `Ubuntu2404`. Update with `brew upgrade eksctl` or download a fresh release.
- **Your cloud region hasn't rolled out Ubuntu 24.04 yet.** AKS rolled out per-region; GKE rolls with K8s version. Try `us-east-1` / `eastus` / `us-central1` first.
- **You re-attached an existing node pool that was originally Ubuntu 22.04.** Delete + recreate the sandbox node pool with the explicit Ubuntu 24.04 flag.
- **GKE cluster is on an older K8s version.** Stable channel currently gives 1.32+, which uses Ubuntu 24.04 by default. If you pinned an older version, upgrade the cluster.

To recover: `bash teardown.sh` then re-run `up.sh`. Both are idempotent.

## LoadBalancer stuck pending > 5 min

```bash
kubectl -n ingress-nginx describe svc ingress-nginx-controller
```

**Per-cloud causes:**

- **AWS (EKS):** the IAM principal lacks `elasticloadbalancing:CreateLoadBalancer`. Check `eksctl` cluster IAM. Or: NLB quota hit; check Service Quotas console.
- **Azure (AKS):** sometimes the public IP allocation lags; wait 2 more minutes. If still pending, `az network public-ip list -g <node-rg>` shows nothing — confirm `--load-balancer-sku standard` was used at cluster create.
- **GCP (GKE):** project quota for in-use external IPs. `gcloud compute project-info describe --project <project>` and look for `IN_USE_ADDRESSES`. Region-level quota: `gcloud compute regions describe <region>`.

The `up.sh` scripts wait 300s by default. If the LB never allocates, the script aborts and you can fix the quota then re-run (it's idempotent).

## cert-manager Certificate stuck in `False`

```bash
kubectl -n daytona get certificate
kubectl -n daytona describe certificate <name>
kubectl -n daytona get challenges
kubectl -n cert-manager logs deployment/cert-manager
```

Common causes:

1. **DNS not propagated yet.** ACME HTTP-01 needs `proxy.<base-domain>` to resolve to the LB hostname. Test with `dig proxy.<base-domain> @1.1.1.1` and `curl http://proxy.<base-domain>/.well-known/acme-challenge/test`.
2. **Wildcard cert under HTTP-01 — impossible.** HTTP-01 cannot validate `*.proxy.<base>`. Prompt 1 issues two non-wildcard certs (`proxy.<base>` and `snapshots.<base>`); per-sandbox subdomains either reuse the proxy cert or need DNS-01 (see below).
3. **Let's Encrypt rate limit hit.** Production endpoint has tight limits. Switch the `ClusterIssuer` to staging temporarily: change `spec.acme.server` to `https://acme-staging-v02.api.letsencrypt.org/directory` and re-apply.

## Runner DaemonSet pod CrashLoopBackOff

```bash
kubectl -n daytona get pods -l app.kubernetes.io/component=runner
kubectl -n daytona describe pod <runner-pod>
kubectl -n daytona logs <runner-pod> -c runner --previous
kubectl -n daytona logs <runner-pod> -c docker-installer --tail=200
kubectl -n daytona logs <runner-pod> -c daytona-binary-installer --tail=200
```

**The host-side bootstrap (docker + sysbox) happens in the `docker-installer` sidecar via `nsenter -t 1 -m -u -n -i`. If `docker-installer` fails, the runner never starts.**

Per-cloud:

- **AKS:** check for the tarball-fallback log line: `dockerd not installed by deb (managed-runtime conflict?) - using static tarball`. If it's NOT there and `docker version` in the docker-installer logs reports an apt conflict, the d1892ef fallback didn't fire. The up.sh script enforces `--os-sku Ubuntu2404` and the post-create `omc::verify_node_ubuntu` gate refuses to continue if nodes aren't on Ubuntu 24.04 — if the gate passed, your nodes are correct.
- **GKE:** PSA enforce=privileged label must be on the namespace. Without it: `Pod ... is forbidden: violates PodSecurity "restricted:latest": privileged ...`. Apply: `kubectl label namespace daytona pod-security.kubernetes.io/enforce=privileged --overwrite`.
- **EKS:** look for `containerd not found` or `sysbox not found` in `docker-installer` logs. Ubuntu **24.04** family AMI is required (eksctl `amiFamily: Ubuntu2404`); the up.sh post-create `omc::verify_node_ubuntu` gate enforces this — if the gate passed, your nodes are correct.

## Sandbox build returns 403 from snapshot manager

This means the runner cannot read/write the customer-owned S3-compatible bucket.

```bash
# What does the runner think its AWS env is?
kubectl -n daytona exec daemonset/daytona-region-runner -c runner -- env | grep AWS_

# Does the snapshot-manager think it can reach the bucket?
kubectl -n daytona logs deployment/daytona-region-snapshot-manager --tail=50 | grep -iE 'error|403|denied'
```

Per-cloud:

- **AWS:** IAM policy on the user/role missing one of `s3:{GetObject,PutObject,DeleteObject,ListBucket,AbortMultipartUpload,ListMultipartUploadParts}`. Confirm with `aws iam list-attached-user-policies --user-name <cluster>-daytona` or `aws iam list-attached-role-policies --role-name <cluster>-runner-irsa`.
- **Azure:** rclone-s3-gateway is down. `kubectl -n daytona get deploy rclone-s3-gateway` and `kubectl -n daytona logs deploy/rclone-s3-gateway`.
- **GCP:** HMAC keys revoked or the GSA lost its `storage.objectAdmin` binding. `gcloud storage hmac list --service-account=<gsa>@<project>.iam.gserviceaccount.com`.

## `credentialMode: irsa` works at chart level but runner exits at startup

This is the **known upstream gap** documented in [`docs/upstream-issues/runner-irsa-support.md`](../../fork/helm-charts/docs/upstream-issues/runner-irsa-support.md). The upstream daytona-runner currently hard-requires non-empty `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` at startup, even when the runner's AWS SDK would otherwise pick up IRSA-projected web-identity tokens.

**Workaround:** use `credentialMode: static` for Prompt 1 testing. The chart's `allowEmptyStaticKeyShim` knob is a placeholder for the partial workaround but is not production-functional today.

## DNS-01 wildcard upgrade path

Prompt 1 ships HTTP-01 for simplicity. To issue a wildcard `*.proxy.<base>` certificate for sandbox subdomains, switch to DNS-01:

```yaml
# cluster-issuer-dns01.yaml — apply AFTER up.sh
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-dns01
spec:
  acme:
    email: you@example.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-dns01-account-key
    solvers:
      - dns01:
          # AWS Route53
          route53:
            region: us-east-1
            # IAM credentials via IRSA (set serviceAccountRef) or AccessKey secretRef
            # See: https://cert-manager.io/docs/configuration/acme/dns01/route53/
          # Azure DNS:
          # azureDNS:
          #   clientID: ...
          #   tenantID: ...
          #   subscriptionID: ...
          #   resourceGroupName: ...
          # GCP Cloud DNS:
          # cloudDNS:
          #   project: <project>
          #   serviceAccountSecretRef:
          #     name: clouddns-dns01-solver-svc-acct
          #     key: key.json
```

Then issue a wildcard cert:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: proxy-wildcard-tls
  namespace: daytona
spec:
  secretName: proxy-wildcard-tls
  issuerRef:
    name: letsencrypt-prod-dns01
    kind: ClusterIssuer
  dnsNames:
    - "*.proxy.byoc.example.com"
```

Reference the certificate from the proxy ingress's `tls.secretName`.

cert-manager DNS-01 docs:

- Route53: <https://cert-manager.io/docs/configuration/acme/dns01/route53/>
- Azure DNS: <https://cert-manager.io/docs/configuration/acme/dns01/azuredns/>
- Cloud DNS: <https://cert-manager.io/docs/configuration/acme/dns01/google/>

## Helm install times out at the wait step

```bash
helm upgrade --install daytona-region ... --wait --timeout 10m
```

If 10 min isn't enough (e.g. very slow AKS node group provisioning), re-run `up.sh` — the helm step is idempotent and will continue waiting from where it left off. Or run the install yourself without `--wait` and poll `kubectl -n daytona get pods` manually.

## State files left over after teardown

The teardown scripts wipe `scripts/<cloud>-setup/.state/` at the end. If something interrupts teardown mid-way:

```bash
rm -rf scripts/aws-setup/.state/   # or azure / gcs
```

Then re-run `teardown.sh` — it's idempotent and will skip resources that no longer exist.

## Where to escalate

- **Chart bug** (helm template fails, values key wrong, etc.) → file against `dalinkstone/helm-charts` with the rendered YAML + helm version.
- **Runner bug** (CrashLoopBackOff, sandbox build fails, etc.) → file against `daytonaio/daytona` with the runner pod logs + chart commit SHA.
- **Cloud setup bug** (up.sh wedges, teardown leaves orphans) → file against `dalinkstone/helm-charts` with cloud + the prompt set you used.
- **Daytona Cloud / dashboard issue** → email Daytona support.
