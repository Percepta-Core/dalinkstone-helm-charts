#!/usr/bin/env bash
# scripts/azure-oss-setup/test/init-test-env.sh
# Interactive helper to populate scripts/azure-oss-setup/.state/sandbox-test.env
# with the credentials the Python smoke tests need. Replaces the old pattern of
# `cp .env.example .env` inside the test/ folder — secrets never live in the
# test directory, only under .state/ which is gitignored repo-wide.
#
# Run once after `up.sh` finishes and you have an admin API key from the dashboard.
#
# Usage:
#   bash scripts/azure-oss-setup/test/init-test-env.sh
#
# Pre-existing values in .state/sandbox-test.env are reused (no re-prompt) unless
# the file is deleted first.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../_lib/common.sh
source "$REPO_ROOT/scripts/_lib/common.sh"

STATE_DIR="$REPO_ROOT/scripts/azure-oss-setup/.state"
TEST_ENV_FILE="$STATE_DIR/sandbox-test.env"
mkdir -p "$STATE_DIR"

if [[ -f "$REPO_ROOT/scripts/azure-oss-setup/.state/prompts.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$REPO_ROOT/scripts/azure-oss-setup/.state/prompts.env"
  set +a
fi

if [[ -f "$TEST_ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$TEST_ENV_FILE"
  set +a
fi

DEFAULT_API_URL=""
if [[ -n "${BASE_DOMAIN:-}" ]]; then
  DEFAULT_API_URL="https://${BASE_DOMAIN}/api"
fi

omc::prompt DAYTONA_API_URL "Daytona API URL (e.g. https://daytona.mycompany.com/api)" "${DEFAULT_API_URL}"
omc::prompt_secret DAYTONA_API_KEY \
  "Daytona admin API key (generate in dashboard: User Settings → API Keys → Create new key)"
omc::prompt DAYTONA_TARGET "Daytona target region" "us"

omc::log INFO ""
omc::log INFO "Optional: set DAYTONA_INSECURE_SKIP_VERIFY=1 below if your TLS cert is still"
omc::log INFO "being provisioned (cert-manager DNS-01 challenge can take 1-2 minutes after install)."
omc::log INFO "Leave blank for production — it disables Python's TLS verification."
omc::prompt DAYTONA_INSECURE_SKIP_VERIFY "Skip TLS verify? (1 = yes, blank = no)" ""

{
  printf 'export DAYTONA_API_URL=%q\n'                 "$DAYTONA_API_URL"
  printf 'export DAYTONA_API_KEY=%q\n'                 "$DAYTONA_API_KEY"
  printf 'export DAYTONA_TARGET=%q\n'                  "$DAYTONA_TARGET"
  if [[ -n "${DAYTONA_INSECURE_SKIP_VERIFY:-}" ]]; then
    printf 'export DAYTONA_INSECURE_SKIP_VERIFY=%q\n'  "$DAYTONA_INSECURE_SKIP_VERIFY"
  fi
} > "$TEST_ENV_FILE"
chmod 600 "$TEST_ENV_FILE"

omc::log INFO ""
omc::log INFO "Wrote $TEST_ENV_FILE (mode 0600)"
omc::log INFO "Run the smoke test with:"
omc::log INFO "  cd $SCRIPT_DIR"
omc::log INFO "  python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt"
omc::log INFO "  python test_sandbox.py"
