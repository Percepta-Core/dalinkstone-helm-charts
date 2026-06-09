"""Shared helpers for the self-hosted Daytona smoke tests.

Centralizes the workaround for the SDK preview-token gap on OSS deployments
so both tests stay focused on their own assertions. Also centralizes the
state-file-loading convention: secrets live in scripts/azure-oss-setup/.state/
sandbox-test.env (gitignored, mode 0600), NEVER in this test directory.
"""
from __future__ import annotations

import os
import pathlib
import ssl
import sys
from urllib.parse import urlparse

import httpx
import urllib3
from dotenv import load_dotenv


_SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
_STATE_ENV = _SCRIPT_DIR.parent / ".state" / "sandbox-test.env"


def load_test_env() -> "None":
    """Load DAYTONA_* env from .state/sandbox-test.env (CI env vars override).

    The .state/ directory is gitignored repo-wide so secrets cannot accidentally
    be committed. If the state file is missing, falls back to whatever is in
    the process environment (this is the CI path: set vars directly).

    `load_dotenv` by default does NOT override existing env vars, so a CI runner
    that already exported DAYTONA_API_KEY=xxx will see its own value, not the
    one from the state file. Local-dev users who only have the state file get
    the state-file values.
    """
    if _STATE_ENV.exists():
        load_dotenv(_STATE_ENV)


def setup_ssl_skip_if_requested() -> bool:
    if os.environ.get("DAYTONA_INSECURE_SKIP_VERIFY", "").lower() in ("1", "true", "yes"):
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
        ssl._create_default_https_context = ssl._create_unverified_context  # type: ignore[attr-defined]
        print("WARN: SSL verification disabled (DAYTONA_INSECURE_SKIP_VERIFY=1)\n")
        return True
    return False


def fail(msg: str) -> "None":
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def assert_self_hosted(api_url: str) -> str:
    api_host = urlparse(api_url).hostname or ""
    if "daytona.io" in api_host.lower():
        fail(
            f"DAYTONA_API_URL points at Daytona Cloud ({api_url}). "
            "These tests ONLY validate self-hosted deployments."
        )
    return api_host


def code_run_via_proxy(
    sandbox, api_url: str, code: str, language: str = "python"
) -> str:
    """Run code in a sandbox via the proxy with a sandbox-scoped preview token.

    Works around an SDK gap on self-hosted OSS: the SDK's process.code_run()
    sends Authorization: Bearer <user-api-key> which the OSS proxy rejects for
    /toolbox/* paths. We fetch the sandbox.authToken via get_preview_link() and
    pass it as X-Daytona-Preview-Token, which the proxy accepts.

    Body schema per CodeRunRequest (daytona_toolbox_api_client):
      code (required), language (required), argv/envs/timeout (optional)
    """
    preview = sandbox.get_preview_link(2280)
    token = getattr(preview, "token", None)
    if not token:
        fail("get_preview_link() returned no token — chart misconfig?")

    api_host = urlparse(api_url).hostname or ""
    url = f"https://proxy.{api_host}/toolbox/{sandbox.id}/process/code-run"
    verify = os.environ.get("DAYTONA_INSECURE_SKIP_VERIFY", "").lower() not in ("1", "true", "yes")

    response = httpx.post(
        url,
        headers={"X-Daytona-Preview-Token": token, "Content-Type": "application/json"},
        json={"code": code, "language": language},
        timeout=60.0,
        verify=verify,
    )
    if response.status_code >= 400:
        fail(
            f"toolbox/process/code-run returned {response.status_code}: "
            f"{response.text[:400]}"
        )
    payload = response.json()
    return (payload.get("result") or payload.get("stdout") or "").strip()
