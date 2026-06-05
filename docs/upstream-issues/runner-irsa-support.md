# Upstream issue draft — Runner: support AWS SDK default credential chain (IRSA-friendly)

> **Status:** DRAFT — file with the daytonaio/daytona repo when ready.
> **Filed against:** `github.com/daytonaio/daytona` (runner module + SDK)
> **Filed by:** helm-charts BYOC contributors
> **Discovered while implementing:** [`charts/daytona-region/`](../../charts/daytona-region/) `services.runner.aws.credentialMode: irsa`

## Summary

The Daytona runner currently hard-requires non-empty `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variables at startup, even when the underlying AWS SDK would otherwise pick up credentials from the [default provider chain](https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html) (EC2 instance profile, ECS task role, EKS IRSA web-identity, AWS SSO, etc.). This blocks every credential-management story that AWS recommends for production:

1. **EKS IRSA** (IAM Roles for Service Accounts) — the canonical AWS pattern for K8s workloads
2. **EC2 instance profile** — the canonical AWS pattern for self-managed VM hosts
3. **AWS SSO + temporary credentials** — the canonical pattern for human-attended runners

A BYOC operator who wants any of these is forced to either (a) inject long-lived static keys into the runner Secret, or (b) work around the validator by emitting empty-string placeholder env vars from the chart (the `allowEmptyStaticKeyShim: true` workaround we ship today).

## Reproducer

Helm chart `daytona-region` v0.1.0 with EKS IRSA configured:

```yaml
services:
  runner:
    aws:
      credentialMode: irsa
      allowEmptyStaticKeyShim: false   # <-- expected to work; currently does not
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/daytona-runner"
    env:
      AWS_REGION: "us-east-1"
      AWS_DEFAULT_BUCKET: "my-org-byoc-region"
      AWS_ENDPOINT_URL: "https://s3.us-east-1.amazonaws.com"
```

The runner pod starts but the daytona-runner process exits with a config-validation error before ever attempting an S3 call, because `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are unset.

## Code references

(File paths and line numbers are valid against `daytonaio/daytona@5df3e80fcfba24e7f01a234c85aeea97d34e8b15` — the HEAD at the time of investigation.)

1. The runner's storage client constructor uses [`credentials.NewStaticV4(...)`](https://github.com/daytonaio/daytona/blob/5df3e80fcfba24e7f01a234c85aeea97d34e8b15/apps/runner/pkg/storage/minio_client.go#L31-L55), which only accepts a hard-coded `(access_key, secret_key)` pair.
2. The runner's [config-loader](https://github.com/daytonaio/daytona/blob/5df3e80fcfba24e7f01a234c85aeea97d34e8b15/apps/runner/cmd/runner/config/config.go#L19-L42) only reads the static env var pair (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) — no `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_ARN`, or fallback paths.
3. The runner's [`mount-s3` subprocess invocation](https://github.com/daytonaio/daytona/blob/5df3e80fcfba24e7f01a234c85aeea97d34e8b15/apps/runner/pkg/docker/volumes_mountpaths.go#L210-L229) explicitly strips env inheritance and passes only the AWS_* values the runner config has, so even if the operator gets ambient IRSA env vars into the runner pod, they would not reach the `mount-s3` child process.
4. The shared Go SDK uploader is also [static-only](https://github.com/daytonaio/daytona/blob/5df3e80fcfba24e7f01a234c85aeea97d34e8b15/libs/sdk-go/pkg/daytona/object_storage.go#L61-L79).
5. The API service's object-storage path is similarly [static-only](https://github.com/daytonaio/daytona/blob/5df3e80fcfba24e7f01a234c85aeea97d34e8b15/apps/api/src/object-storage/services/object-storage.service.ts#L33-L48) and demands `S3_ACCESS_KEY` / `S3_SECRET_KEY` + STS endpoint / account-id / role-name. The IRSA fix proposed below should be mirrored to the API side as a follow-up.

## Proposed change

Add a `credentialMode` / detect-default-chain capability to the runner's storage client:

```go
// Pseudocode for apps/runner/pkg/storage/minio_client.go
if hasStaticKeys(cfg) {
    creds = credentials.NewStaticV4(cfg.AccessKey, cfg.SecretKey, "")
} else {
    creds = credentials.NewIAM("")   // mc-style default chain (IMDS, ECS, EKS web-identity)
}
```

Or — alternative interface — accept the `minio-go` `credentials.Chain` provider:

```go
creds := credentials.NewChainCredentials([]credentials.Provider{
    &credentials.EnvAWS{},
    &credentials.FileAWSCredentials{},
    &credentials.IAM{Client: httpClient},   // covers EC2, ECS, EKS IRSA
})
```

The detection should happen at storage-client construction, not at config validation, so the runner's startup-time config check should be relaxed to:

- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` are required ONLY when neither IRSA env vars (`AWS_WEB_IDENTITY_TOKEN_FILE` + `AWS_ROLE_ARN`) nor an EC2/ECS metadata service is detectable.
- Otherwise, the storage client falls back to the default chain.

For the `mount-s3` subprocess: pass `--no-sign-request` is the wrong fix; instead, allow the parent process to inherit ambient AWS env vars when no explicit static creds are set, OR explicitly resolve credentials via the AWS SDK first and then forward them to the subprocess as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`.

## Acceptance criteria

- Runner pod with `services.runner.aws.credentialMode: irsa` (and `allowEmptyStaticKeyShim: false`) starts cleanly when the SA carries the IRSA role-arn annotation.
- Build-context fetch from S3 succeeds using the IRSA-projected web-identity token.
- Sandbox creation via the declarative builder works end-to-end.
- `mount-s3` mounts succeed under IRSA.
- Existing static-credential operators see no behavior change.

## Chart-side workaround currently shipped

While this upstream change is pending, `daytona-region` v0.1.0 ships a chart-level `services.runner.aws.allowEmptyStaticKeyShim` knob (default false). When true, the chart emits empty-string `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in the runner Secret to satisfy the validator while the AWS SDK is supposed to use the IRSA token at runtime. This is a workaround, not a fix — the runner's S3 client never actually consults the default chain, so the workaround surfaces a different failure (S3 access denied at runtime) instead of a startup failure. Operators today must use `credentialMode: static` for IRSA-incompatible behavior.

## Related upstream issues

- daytonaio/helm-charts#11 — daytona-runner fails on containerd-only Kubernetes
- daytonaio/helm-charts#22 — fix: add `--force-conflicts` to dpkg docker install in runner daemonset

## Suggested labels

`area/runner`, `area/storage`, `area/aws`, `type/feature`, `priority/p1`
