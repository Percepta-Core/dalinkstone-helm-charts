# Code review — BYOC scripts + docs (ulw/p1-foundation)

## Verdict: PASS (binding) — 1 medium fix recommended pre-merge, otherwise ship

Scope reviewed: 13 files (1 shared lib, 6 per-cloud up/teardown, 3 helm values templates, 2 static QA gates, 5 docs). Static gates (S1/S5/S6, helm-unittest 16/16, helm lint) trusted as GREEN per prompt. Focus was on logic, safety, and contract adherence.

## Per-question (1 line each)

Q1 SHELL INJECTION: SAFE — every operator-supplied value is double-quoted at the `aws`/`az`/`gcloud`/`kubectl`/`helm` call sites; no `eval`, no `sh -c`, no unquoted expansions; heredocs interpolate into YAML/JSON literals only (operator is the trust boundary on their own provisioning host).

Q2 STATE SECRECY: PARTIAL — `prompts.env`, `iam-keys.env`, `rclone-keys.env`, `hmac.env` are correctly `chmod 600` and wiped by teardown; **`.state/values-region.yaml` is NOT chmod'd** despite carrying `DAYTONA_API_KEY` + `IAM_SECRET_KEY` / `HMAC_SECRET_KEY` / `RCLONE_SECRET_KEY` in plaintext, and docs falsely claim mode 644 for it. Teardown does wipe the directory.

Q3 IDEMPOTENCY: STRONG — every resource gated by an existence check: `eksctl get cluster`, `az aks show`, `gcloud container clusters describe`, `aws s3api head-bucket`, `gcloud storage buckets describe`, `aws iam get-user` / `get-role`, `gcloud iam service-accounts describe`, HMAC keys cached in `hmac.env`. Prompts persist across reruns. One minor gap: if `iam-keys.env` is wiped while the IAM user still exists, the next `up.sh` creates a 2nd access key (AWS limit is 2; not a blocker, but documented in nits).

Q4 TEARDOWN COVERAGE: 1:1 — AWS teardown deletes EKS+S3+IAM-user+keys+IRSA-role+S3-policy (matches up.sh creates). Azure uses the nuclear `az group delete` which removes AKS+storage+container+LB in one shot (intentional, called out in comments). GCP teardown deletes HMAC keys (with sweep for orphans), bucket-IAM-binding, GSA, GCS bucket, GKE cluster. All match.

Q5 OPERATOR-SAFE: YES — every destructive op gated by `omc::confirm` (returns non-zero → script exits cleanly on N); `OMC_NONINTERACTIVE=1` deliberately blocks confirms (cannot bypass); no `rm -rf /` patterns; the only `rm -rf` targets are `$STATE_DIR` (correctly resolved via `omc::state_dir` to `$SCRIPT_DIR/.state`) — both `$SCRIPT_DIR` and `$STATE_DIR` are always non-empty by construction (no risk of expanding to `/`).

Q6 PROMPT 1 CONTRACT: HONORED — all 3 rendered templates set `services.runner.mainContainer.enabled: true` (line 68/74/79). AWS sets `services.runner.aws.credentialMode: "${RUNNER_AWS_CREDENTIAL_MODE}"` (with static/irsa input validated at up.sh:57-59); Azure/GCP hard-pin `"static"` with Workload-Identity placeholders for Prompt 2. Both proxy and snapshot-manager ingresses carry `cert-manager.io/cluster-issuer: "letsencrypt-prod"`. AWS env block under `services.runner.env` populates AWS_REGION/AWS_DEFAULT_BUCKET/AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_ENDPOINT_URL.

Q7 DOCS HONESTY: TRUTHFUL — IRSA upstream gap is called out in `aws.md` "Known gaps" + `troubleshooting.md` + cross-link to `docs/upstream-issues/runner-irsa-support.md` and surfaced via WARN log in `aws-setup/up.sh:227-228`. AKS tarball fallback documented in `azure.md` with the exact grep proof (`'static.*tarball|dockerd not installed by deb'`). GKE PSA privileged label documented in `gcp.md` step 6 + applied at `gcs-setup/up.sh:155-156`. Wildcard DNS-01 caveat: HTTP-01 limit called out per-cloud + full upgrade-path YAML in `troubleshooting.md`.

## Decisions A-F

A LEGACY MOVED: yes — `.legacy/` dirs exist under all 3 setup dirs with `repro.sh`, `runner-bootstrap.sh`, `ecr-setup.sh`/`gcr-setup.sh`, `diagnose-*.sh`, README; top-level retains only `up.sh`, `teardown.sh`, `e2e.sh`, `README.md`, `values-region.yaml.tmpl` (+ Azure-only `rclone-deployment.yaml.tmpl`) as spec'd.

B ENTRYPOINT up.sh: yes — every doc + summary block invokes `bash scripts/<cloud>-setup/up.sh`; no `bootstrap.sh` or `e2e.sh`-as-entrypoint references.

C SHARED LIB: yes — `scripts/_lib/common.sh` exists with `omc::log`, `omc::die`, `omc::need_cmd`, `omc::prompt`, `omc::prompt_secret`, `omc::confirm`, `omc::render_template`, `omc::state_dir`, `omc::wait_lb_address`, `omc::print_dns_records`, `omc::ingress_nginx_install`, `omc::cert_manager_install`, `omc::cluster_issuer_apply`, `omc::helm_install_wait`. Honors `OMC_NONINTERACTIVE` + `OMC_YES`. All 6 scripts source it correctly.

D DOCS LOCATION: yes — `/Users/dalinstone/main/test/byoc-overhaul/{README,aws,azure,gcp,troubleshooting}.md` present and internally cross-linked.

E IRSA NAMING: yes — `aws-setup/up.sh:197` sets `IRSA_ROLE_NAME="${CLUSTER_NAME}-runner-irsa"` (per-service); teardown deletes the same name. Trust policy binds to `system:serviceaccount:daytona:${CLUSTER_NAME}-daytona-region-runner` (per-service SA).

F HTTP-01: yes — `common.sh:235` `cluster_issuer_apply` writes a single `http01.ingress.class: nginx` solver. Docs explicitly state HTTP-01 limits and provide the DNS-01 wildcard upgrade path in `troubleshooting.md:77-130`.

## Blockers (must fix; empty = PASS)

_(none — verdict is PASS; the one MEDIUM below is strongly recommended pre-merge but not gate-blocking since the file is wiped on teardown and never leaves the operator's host)_

## Nits (post-merge OK)

- **[MEDIUM, Q2]** `scripts/_lib/common.sh:119` `omc::render_template` writes the rendered output (which contains DAYTONA_API_KEY, IAM secret, HMAC secret, rclone secret depending on cloud) at the process default umask (typically 644). Add `chmod 600 "$dst"` right after the `envsubst` line so the rendered values file matches the secrecy of the `.state/*.env` files that feed it. Docs (`aws.md:131-132`, `azure.md:112`, `gcp.md:117`) currently mis-state the file mode as 644 — either harden it (preferred) or correct the docs. Recommended fix: harden + update docs.
- **[LOW, Q3]** `aws-setup/up.sh:182-184`: if the operator manually deletes `.state/iam-keys.env` while the IAM user still exists, the next `up.sh` calls `aws iam create-access-key` again; AWS caps an IAM user at 2 active keys, so the third invocation in this scenario hard-fails with `LimitExceeded`. Either gate on `aws iam list-access-keys` count, or document the manual-cleanup hint in `aws.md` "State files" table.
- **[LOW, Q1 hygiene]** `aws-setup/up.sh:81-107` and `:131-150` and `:198-215` write `eksctl` YAML / IAM JSON via heredocs that interpolate `${CLUSTER_NAME}` / `${S3_BUCKET}` / `${OIDC_HOST}` without YAML/JSON escaping. The operator is the trust boundary (they type these values themselves on their own host), so this is not a security finding, but a malformed name with embedded quotes or newlines would silently corrupt the generated artifact. Consider validating prompts against `^[a-z0-9][-a-z0-9]*$` in `common.sh::omc::prompt` (or a new `omc::prompt_dns_label` helper).
- **[LOW, Q4 GCP]** `gcs-setup/teardown.sh:69-81` deletes HMAC keys from `$HMAC_ACCESS_KEY` THEN sweeps any remaining keys on the GSA. Good. But the sweep silently swallows `gcloud storage hmac delete` failures (`|| true`); if a key fails to deactivate first, the delete will fail too. Either chain the deactivate explicitly or log a WARN on delete failure.
- **[LOW, Q5 azure]** `azure-setup/teardown.sh:53` uses `az group delete --yes --no-wait`. The `--no-wait` makes the teardown fast but means the script exits "succeeded" before AKS+storage are actually gone. Docs do call this out (`azure.md:96-98`), but consider an `OMC_WAIT=1` opt-in for `--no-wait`-off (operator wants billing confirmation immediately).
- **[NIT docs]** `README.md:18` references `scripts/<cloud>-setup/e2e.sh` as step 7 of the test loop, which the K8s-native overhaul intentionally retains. Worth a one-line note in `README.md` that `e2e.sh` is the legacy SDK smoke test (still works, optional) so reviewers don't mistake it for the K8s-native entrypoint.
- **[NIT]** `common.sh:121` `unresolved="$(grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$dst" || true)"` runs `grep` on the rendered file; this is correct behavior, but it also flags literal `${...}` strings that envsubst would not substitute (none today, but if a future template includes a literal helm template directive like `{{ .Values.foo }}` adjacent to `${LITERAL}`, the gate could false-positive). Not a current bug.

## Positive observations

- Two-stage credential persistence (`prompts.env` + `iam-keys.env` / `hmac.env` / `rclone-keys.env`) is clean and lets partial-failure reruns reuse exactly the secrets the prior attempt minted.
- `omc::confirm` + `OMC_YES=1` + `OMC_NONINTERACTIVE=1` triad gives operators an audited override path without weakening the default safety posture.
- Per-cloud `dns01` upgrade documentation in `troubleshooting.md` is concrete (YAML included) and per-provider — operators can lift it directly.
- `aws-setup/up.sh:227-228` proactively WARNs about the IRSA upstream gap at the IAM-creation step instead of letting the operator discover it at runtime — surfacing this in the flow (not just docs) is the right call.
- `gcs-setup/up.sh:155-156` PSA-privileged label is applied BEFORE the helm install, so the privileged DaemonSet does not race the admission webhook on first apply.
- `azure-setup/up.sh:166-180` mints rclone gateway credentials with `openssl rand` (cryptographically sound), stores them 0600, and reuses them on re-run — good ephemeral-credential hygiene.
- Teardown scripts use `set -uo pipefail` (no `-e`) so a single failed AWS API call doesn't strand the operator with half-cleaned cloud resources — pragmatic, correct for cleanup paths.
- AWS S3 region special-case (`us-east-1` cannot pass `LocationConstraint`) is correctly handled at `aws-setup/up.sh:117-122`. Classic gotcha; nice catch.
- `common.sh::omc::wait_lb_address` handles both `ip` (GKE/AWS) and `hostname` (AWS NLB CNAME) forms of LoadBalancer ingress — portable across clouds.

## Final verdict: PASS

All 7 security/correctness questions resolved SAFE/STRONG/1:1/YES/HONORED/TRUTHFUL with one MEDIUM-confidence Q2 finding that is recommended-but-not-blocking (rendered-values-file mode + docs claim mismatch; file is teardown-wiped and never leaves operator's host). All 6 plan-locked decisions (A-F) implemented as described. Ship it; track the MEDIUM as a fast follow-up.
