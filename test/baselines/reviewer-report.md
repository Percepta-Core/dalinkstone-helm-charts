# Focused code review — ulw/p1-foundation

<!-- Reviewer: code-reviewer agent (opus), 2026-06-04 -->
<!-- Scope: 5 files only (runner-daemonset.yaml, runner-docker-daemon-configmap.yaml, runner-secret.yaml, runner-serviceaccount.yaml, values.yaml) -->
<!-- Time spent: ~12 min. Verifier evidence (16/16 tests + baseline + lint) trusted as PASS. -->

## Verdict: PASS

## Per-decision (one line each)

**A: APPROVE** — `runner` main container at `runner-daemonset.yaml:750-794` is a NEW sibling block, fully gated by `if .Values.services.runner.mainContainer.enabled` with `default: false` (values.yaml:407-408); it does NOT replace `daytona-binary-installer` (which is still rendered at lines 592-749 under its own `daemonInstaller.enabled` gate).

**B: APPROVE** — `envFrom` at `runner-daemonset.yaml:774-776` uses `secretRef` to `{fullname}-region-config` with `optional: true`, matching the verifier's rendered YAML evidence (S2, lines 82-84 of verifier-evidence.md); pod will start cleanly before the registration hook populates the secret.

**C: APPROVE** — New ConfigMap `runner-docker-daemon-configmap.yaml` is gated by `and services.runner.enabled (or docker.daemonConfig.enabled (gt (len ... insecureRegistries) 0))` (line 15), mount in daemonset uses identical gate at line 784, subPath: daemon.json correctly scopes the mount to a single file (not the whole `/etc/docker/` dir).

**D: APPROVE** — `add_host_alias()` defined once at `runner-daemonset.yaml:130-147` with awk-tmp-merge + atomic `mv /etc/hosts.tmp /etc/hosts`, idempotent (overwrites existing entries by hostname). Both the static loop (lines 149-154) and the `dynamicHostAliases` loop (lines 156-163) route through it. Empty-arg guard at line 132 prevents bad calls when values are empty.

**E: APPROVE** — Verifier confirms `hack/check-no-install-sh.sh` exits 0, `runner/install.sh` carries LEGACY banner in first 5 lines, and `scripts/{aws,azure,gcs}-setup/README.md` all carry "⚠️ LEGACY / REPRO FLOW" banners. Out-of-scope for inline review but evidence is concrete.

**F: APPROVE** — `Chart.yaml:5` reads `version: 0.1.0` (from prior 0.0.12), a minor bump per semver for an additive opt-in feature. AppVersion `v0.167.0` unchanged. Correct.

## Security answers

**Q1 SHELL INJECTION: SAFE (with documented caveat)** — At runtime, `add_host_alias()` passes ip/name through shell-quoted variables (`ip="$1"; name="$2"`) into `nsenter ... sh -c "awk -v ip=\"$ip\" -v name=\"$name\" ..."`, which correctly quotes them for awk. The static-aliases injection vector is Helm template substitution at chart-render time (`add_host_alias "{{ $ip }}" "{{ . }}"`, line 152) — values containing `"` or `\` would break the literal. However, `services.runner.hostAliases` is admin-controlled (helm values = cluster admin trust level), matching the standard Helm trust model. Not a vulnerability boundary; same posture as every other Helm chart that renders shell scripts. Flagged as a nit below for hardening.

**Q2 CREDENTIAL LEAK: SAFE** — `runner-secret.yaml` uses `stringData:` (line 26), which is the standard K8s Secret API convention; the API server base64-encodes it server-side. No `data:` mixing. `helm template` output WILL contain the values in plaintext (that is unavoidable for any rendered helm secret — operators must not commit rendered manifests). The `credentialMode: irsa` + `shim:false` path correctly OMITS both AWS keys (lines 32-38), verified by S4 evidence. No log/echo of secret contents in any of the 5 reviewed files. No regression vs the pre-change baseline (S6 PASS).

**Q3 BACKWARD-COMPAT: PRESERVED** — Every new code path is gated:
  - `mainContainer` block: `if .Values.services.runner.mainContainer.enabled` (default false → daemonset.yaml:750)
  - `var-lib-daytona` volume: same gate (daemonset.yaml:800)
  - `runner-docker-daemon-config` volume + mount: `or docker.daemonConfig.enabled (gt (len insecureRegistries) 0)` (default both false/empty → daemonset.yaml:784, 805)
  - New ConfigMap file: same combined gate (configmap:15)
  - Secret `AWS_ACCESS_KEY_ID/SECRET` keys: `credentialMode: static` default emits them exactly as before (secret:32-34)
  - SA `automountServiceAccountToken`: only renders when value is not `nil` (serviceaccount:14), preserving kubelet default
  - `hack/check-baseline-compat.sh` re-run in this review: `OK [daytona-region]: baseline preserved`, exit 0.

## Blockers (empty = PASS)

(none)

## Nits (post-merge OK)

- `runner-daemonset.yaml:152` — `add_host_alias "{{ $ip }}" "{{ . }}"` does not escape `"` or `\` in operator-supplied hostname/ip strings. A malformed value like `hostnames: ['foo"bar']` would break shell quoting at render time. Trust boundary makes this low-severity (admin-only input), but a `printf "%q"` or `quote` filter via Helm's `squote`/`quote` would harden it. Suggested: `add_host_alias {{ $ip | quote }} {{ . | quote }}`. Confidence: HIGH.
- `runner-daemonset.yaml:165` — `grep -E "registry|minio|snapshot-manager"` is hard-coded. If an operator's `dynamicHostAliases` includes other names, the verification log won't show them. Cosmetic only.
- `runner-secret.yaml:27-28` — `DAYTONA_API_URL` and `SERVER_URL` both `required` the same `.Values.daytonaApiUrl`, causing two identical error messages on misconfig. Cosmetic.
- `runner-daemonset.yaml:621-639` — `daytona-binary-installer` hardcodes throwaway secrets as env literals (`API_TOKEN: "installer"`, `AWS_ACCESS_KEY_ID: "installer"`). These are explicitly documented as throwaway, but they show up as plaintext in pod specs. Pre-existing (not introduced in this PR), out of scope.
- `runner-docker-daemon-configmap.yaml:25-38` — Two consecutive `{{- with ... }}` blocks could emit a JSON document with a trailing comma if both `dns` and `insecureRegistries` are unset AND `daemonConfig.enabled: true` (would render `{ "log-driver": ... }` which is fine — actually safe, since `with` is a no-op on empty). Verified: JSON is well-formed in all four combinations of (`dns`, `insecureRegistries`). No bug.
- `values.yaml:443-447` — Commented-out `automountServiceAccountToken:` could confuse operators; consider documenting "(default: unset → kubelet default)" more prominently. Cosmetic.
- The `nsenter -t 1 -m -u -n -i sh -c` host-namespace escape requires `privileged: true` + `hostPID: true` (both already set). Worth a SECURITY.md note that this DaemonSet has full root on every node — operators MUST restrict who can edit `services.runner.*` in their values. Out of scope for this review, suggest tracking as a doc task.

## Final verdict: PASS

All 6 architectural decisions APPROVE; all 3 security questions SAFE/PRESERVED; zero blockers; nits are post-merge OK. Verifier evidence (16/16 helm-unittest + lint + baseline) is concrete and re-verified by spot-running `hack/check-baseline-compat.sh` in this review (exit 0). Ship it.
