# Azure-deployed Daytona OSS smoke tests

End-to-end sandbox tests for the self-hosted Daytona OSS instance deployed to
AKS via `helm-charts/scripts/azure-oss-setup/up.sh`. All tests explicitly fail
if `DAYTONA_API_URL` points at Daytona Cloud (`api.daytona.io`).

Two tests are provided:

| File | Purpose | Side effect |
|---|---|---|
| `test_sandbox.py` | Smoke: create → exec → delete | None (clean teardown) |
| `test_sandbox_keep.py` | Persistent: create → exec → write marker → STOP | One stopped sandbox preserved for manual inspection |

Both share `_helpers.py`, which contains the OSS-specific workaround for the
SDK preview-token gap (the SDK's `process.code_run()` doesn't pass a
sandbox-scoped token, which the OSS proxy requires for `/toolbox/*` paths).

## Secrets live in `.state/`, NEVER in this folder

Credentials (Daytona API URL, admin API key, region) are loaded from
`scripts/azure-oss-setup/.state/sandbox-test.env`. That directory is
`.gitignored` repo-wide via the root `.gitignore`'s `**/.state/` rule. The
test folder itself is also defensive — `.gitignore` here blocks `.env`,
`.venv/`, and `__pycache__/` from ever being staged.

**Do not** create a `.env` file inside this directory. The old pattern of
`cp .env.example .env` is gone — the helper script writes to `.state/`
instead.

## Setup (one-time, after `up.sh` finishes)

```bash
# From the helm-charts repo root
cd scripts/azure-oss-setup/test

# 1. Get an admin API key from your dashboard
#    https://<your-base-domain>/dashboard
#    User Settings → API Keys → Create new key
#    (Sign in with Dex first if you haven't already)

# 2. Run the helper to write your test credentials into .state/sandbox-test.env
#    (interactive — prompts for API URL, API key, region, optional TLS skip)
bash init-test-env.sh

# 3. Set up the Python venv
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

The helper is idempotent — re-running it preserves existing values unless you
delete `.state/sandbox-test.env` first.

## Bypass TLS verification while LE cert is provisioning

The chart's api ingress includes a wildcard SAN (`*.<baseDomain>`), which
requires DNS-01 (HTTP-01 can't satisfy wildcards). cert-manager can take ~2
minutes after install to complete the DNS-01 challenge with Cloudflare.

If you want to run the smoke test before the cert is fully provisioned, set
`DAYTONA_INSECURE_SKIP_VERIFY=1` when running `init-test-env.sh`. The Python
helper (`_helpers.setup_ssl_skip_if_requested`) honors that env var and
disables urllib3's TLS verification. **Only for testing** — never production.

To re-enable verification later: re-run `bash init-test-env.sh` and leave the
skip-verify field blank, OR edit `.state/sandbox-test.env` and remove the
`DAYTONA_INSECURE_SKIP_VERIFY` line.

## Run the tests

### Smoke test (clean teardown)

```bash
source .venv/bin/activate
python test_sandbox.py
```

Expected output:

```
=== SMOKE TEST against https://<your-base-domain>/api ===
Target/region: us

[1/4] Creating sandbox...
[2/4] Running Python in sandbox (via proxy preview token)...
  stdout: Hello from Azure-deployed Daytona!
[3/4] Querying sandbox uname...
[4/4] Deleting sandbox...

PASS - smoke test complete. No leftover state.
```

### Persistent test (leaves stopped sandbox with marker file)

```bash
python test_sandbox_keep.py
```

Same flow, but `stop()`s the sandbox instead of `delete()`ing, and writes a
`HELLO_AZURE_DEPLOYMENT.txt` marker inside. Restart the sandbox from the
dashboard and `cat` the marker for visual proof of end-to-end execution.

## CI usage (no `.state/` file needed)

In CI, set the env vars directly. `_helpers.load_test_env()` calls `load_dotenv`
which by default does **not** override existing env vars, so CI-exported values
take precedence over anything in `.state/sandbox-test.env`.

```yaml
- name: smoke test
  env:
    DAYTONA_API_URL: ${{ vars.DAYTONA_API_URL }}
    DAYTONA_API_KEY: ${{ secrets.DAYTONA_API_KEY }}
    DAYTONA_TARGET: us
  run: |
    cd scripts/azure-oss-setup/test
    python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
    python test_sandbox.py
```

## Failure modes

| Symptom | Likely cause |
|---|---|
| `ERROR: DAYTONA_API_URL points at Daytona Cloud` | You set the SaaS URL by accident — use your AKS ingress URL |
| `httpx.ConnectError` to your domain | DNS not propagated yet, OR ingress LB not ready |
| `SSL: CERTIFICATE_VERIFY_FAILED ... self-signed certificate` | cert-manager hasn't issued the LE cert yet — wait, or set `DAYTONA_INSECURE_SKIP_VERIFY=1` |
| `401 Unauthorized` | API key wrong/expired — regenerate in dashboard, re-run `init-test-env.sh` |
| `404 on POST /workspaces` | API URL missing `/api` path suffix |
| `Failed to create sandbox: No available runners` | Runner not READY in DB — run `bash ../infra/diagnose.sh` |
| Sandbox stuck in `pending` | Sandbox node missing `daytona-sandbox-c=true` label OR runnermanager unhealthy |
| Sandbox URL not under your domain | Chart's `baseDomain` value wrong — re-render values |

## Related infra tests

- `scripts/azure-oss-setup/test/infra/diagnose.sh` — 8-step live diagnostic
- `scripts/azure-oss-setup/test/infra/fresh-install-validate.sh` — hard-fail assertion gate after `up.sh`
- `scripts/azure-oss-setup/test/infra/recycle-node.sh` — node recycle regression test

## Re-running

The smoke test is idempotent. Each run creates a fresh sandbox and deletes it
on exit. No state lives between runs.
