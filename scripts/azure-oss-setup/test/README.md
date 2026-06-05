# Azure-deployed Daytona OSS smoke tests

End-to-end tests for the self-hosted Daytona OSS instance deployed to AKS via
`helm-charts/scripts/azure-oss-setup/up.sh`. All tests explicitly fail if
`DAYTONA_API_URL` points at Daytona Cloud (`api.daytona.io`).

Two tests are provided:

| File | Purpose | Side effect |
|---|---|---|
| `test_sandbox.py` | Smoke: create → exec → delete | None (clean teardown) |
| `test_sandbox_keep.py` | Persistent: create → exec → write marker → STOP | One stopped sandbox preserved for manual inspection |

Both share `_helpers.py`, which contains the OSS-specific workaround for the
SDK preview-token gap (the SDK's `process.code_run()` doesn't pass a
sandbox-scoped token, which the OSS proxy requires for `/toolbox/*` paths).

## What this test proves

- The SDK is talking to YOUR Azure-deployed API (NOT `api.daytona.io`)
- Sandbox URLs are under YOUR base domain (proves traffic is local)
- The in-cluster runnermanager scheduled a runner pod on YOUR sandbox node
- Code execution works inside the sandbox
- Cleanup is wired correctly

## Setup (one-time)

```bash
cd ~/main/test/azure-deployment-test

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

## Get an API key from the dashboard

1. Open the dashboard:
   - https://daytona.shadrachmeshachabednego.com/dashboard
2. Sign in via Dex (first-time admin setup, default `admin` / `password` unless
   the chart's `dex.config.staticPasswords` was customized)
3. Navigate to **User Settings → API Keys → Create new key**
4. Copy the key into `.env` as `DAYTONA_API_KEY`

## Run the tests

### Smoke test (clean teardown)

```bash
python test_sandbox.py
```

Expected output:

```
=== SMOKE TEST against https://daytona.shadrachmeshachabednego.com/api ===
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

Expected output ends with:

```
[5/5] Stopping (NOT deleting) sandbox so you can inspect it later...

PASS - sandbox is stopped but preserved.

Inspect via the dashboard:
  Dashboard:  https://daytona.shadrachmeshachabednego.com/dashboard
  Sandbox ID: <uuid>
  Marker:     HELLO_AZURE_DEPLOYMENT.txt in the sandbox workspace
```

Then in the dashboard, find the sandbox by ID, click **Start**, open a terminal
inside the sandbox, and `cat HELLO_AZURE_DEPLOYMENT.txt` — that's the on-disk
proof of end-to-end execution.

Expected output:

```
=== Testing self-hosted Daytona at https://daytona.shadrachmeshachabednego.com/api ===
Target/region: us

[1/4] Creating sandbox...
  id=xxxxxxxx
  state=started
  url=https://xxxxxxxx.proxy.daytona.shadrachmeshachabednego.com  (self-hosted)

[2/4] Running Python in sandbox...
  stdout: Hello from Azure-deployed Daytona!

[3/4] Querying sandbox uname...
  uname: posix.uname_result(sysname='Linux', ...)

[4/4] Deleting sandbox...
  deleted xxxxxxxx

PASS — self-hosted Daytona is fully operational.
```

## Failure modes the test catches

| Symptom | Likely cause |
|---|---|
| `ERROR: DAYTONA_API_URL points at Daytona Cloud` | You set the SaaS URL by accident — use the AKS ingress URL |
| `httpx.ConnectError` to your domain | DNS not propagated yet, OR ingress LB not ready |
| `401 Unauthorized` | API key wrong/expired — regenerate in dashboard |
| `404 on POST /workspaces` | API URL missing `/api` path suffix |
| Sandbox stuck in `pending` | Sandbox node missing `daytona-sandbox-c=true` label OR runnermanager unhealthy |
| Sandbox URL not under your domain | Chart's `baseDomain` value wrong — re-render values |

## Re-running

The test is idempotent — each run creates a fresh sandbox and deletes it on
exit. No state lives between runs.
