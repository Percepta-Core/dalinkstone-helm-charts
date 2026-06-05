#!/usr/bin/env python3
"""Smoke test: create sandbox, execute code, DELETE.

Quick PASS/FAIL test that leaves no Daytona-side state behind. Use this for CI
or when you just want a "does it work right now?" answer.

For a test that leaves an inspectable artifact, see test_sandbox_keep.py.
"""
from __future__ import annotations

import os
from urllib.parse import urlparse

from dotenv import load_dotenv
from daytona import Daytona, DaytonaConfig

from _helpers import (
    assert_self_hosted,
    code_run_via_proxy,
    fail,
    setup_ssl_skip_if_requested,
)


def main() -> "None":
    setup_ssl_skip_if_requested()
    load_dotenv()

    api_url = os.environ.get("DAYTONA_API_URL", "").rstrip("/")
    api_key = os.environ.get("DAYTONA_API_KEY", "")
    target = os.environ.get("DAYTONA_TARGET", "us")

    if not api_url:
        fail("DAYTONA_API_URL is not set (see .env.example)")
    if not api_key or api_key == "replace-me-from-dashboard":
        fail("DAYTONA_API_KEY is not set — generate one in the dashboard")
    api_host = assert_self_hosted(api_url)

    print(f"=== SMOKE TEST against {api_url} ===")
    print(f"Target/region: {target}\n")

    config = DaytonaConfig(api_key=api_key, api_url=api_url, target=target)
    client = Daytona(config)

    print("[1/4] Creating sandbox...")
    sandbox = client.create()
    print(f"  id={sandbox.id}")
    print(f"  state={getattr(sandbox, 'state', 'unknown')}\n")

    try:
        print("[2/4] Running Python in sandbox (via proxy preview token)...")
        out = code_run_via_proxy(
            sandbox, api_url, 'print("Hello from Azure-deployed Daytona!")'
        )
        print(f"  stdout: {out}")
        if "Hello from Azure-deployed Daytona!" not in out:
            fail(f"unexpected sandbox output: {out!r}")
        print()

        print("[3/4] Querying sandbox uname...")
        uname_out = code_run_via_proxy(
            sandbox, api_url, "import os; print(os.uname())"
        )
        print(f"  uname: {uname_out}\n")
    finally:
        print("[4/4] Deleting sandbox...")
        sandbox.delete()
        print(f"  deleted {sandbox.id}\n")

    print("PASS - smoke test complete. No leftover state.")


if __name__ == "__main__":
    main()
