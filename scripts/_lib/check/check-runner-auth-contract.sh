#!/usr/bin/env bash
# Asserts the runner-auth contract in charts/daytona: api's DEFAULT_RUNNER_API_KEY
# (which seeds the default-runner DB row's apiKey at api bootstrap) MUST match the
# runner pod's API_TOKEN (the bearer token presented to /api/jobs/poll). When they
# mismatch the runner gets 401 forever, because the api's findByApiKey() DB lookup
# in apps/api/src/auth/api-key.strategy.ts cannot resolve the token.
#
# Scenarios:
#   S1 (default render): api and runner both emit "secret_api_token"
#   S2 (single source override): --set services.runner.env.API_TOKEN=X
#       → api DEFAULT_RUNNER_API_KEY == runner API_TOKEN == runner-manager API_KEY == X
#   S3 (explicit decouple):  --set services.api.env.DEFAULT_RUNNER_API_KEY=Y
#       → api gets Y; runner keeps its own value (operator opted out of auto-sync)
#       → runner-manager still uses the runner token unless explicitly overridden
#
# Exit codes:
#   0 — all scenarios pass
#   1 — at least one scenario regressed
set -uo pipefail

CHART="${CHART:-./charts/daytona}"
FAIL=0

extract_env_value() {
  # Args: file, container_filter_grep_pattern, env_name
  # Walks the rendered yaml linearly, picks the FIRST `name: $env_name` whose
  # immediate preceding kind:/component context matches the filter. Returns the
  # value (without quotes). Empty if not found.
  local file="$1" filter="$2" env_name="$3"
  awk -v filter="$filter" -v env="$env_name" '
    /^kind: / { in_filter=0 }
    $0 ~ filter { in_filter=1 }
    in_filter && $0 ~ ("name: " env "$") { getline; sub(/^[[:space:]]*value:[[:space:]]*"?/, ""); sub(/"?$/, ""); print; exit }
  ' "$file"
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS [$label]: got '$actual'"
  else
    echo "  FAIL [$label]: expected '$expected', got '$actual'"
    FAIL=1
  fi
}

count_grep() {
  local file="$1" pattern="$2"
  grep -c "$pattern" "$file" 2>/dev/null || echo 0
}

run_scenario() {
  local label="$1" set_args="$2" expected_api="$3" expected_runner="$4" expected_manager="$5"
  local out
  out="$(mktemp)"
  if ! eval "helm template $CHART $set_args" >"$out" 2>/dev/null; then
    echo "FAIL [$label]: helm template failed"
    FAIL=1
    rm -f "$out"
    return
  fi
  echo "[$label] $set_args"

  local default_runner_count
  default_runner_count="$(count_grep "$out" "name: DEFAULT_RUNNER_API_KEY$")"
  assert_eq "$label/env-count" "$default_runner_count" "4"

  local api_val runner_val manager_val
  api_val="$(extract_env_value "$out" "daytona-api$" "DEFAULT_RUNNER_API_KEY")"
  runner_val="$(extract_env_value "$out" "daytona-runner$" "API_TOKEN")"
  manager_val="$(extract_env_value "$out" "daytona-runnermanager$" "API_KEY")"

  assert_eq "$label/api-DEFAULT_RUNNER_API_KEY" "$api_val" "$expected_api"
  assert_eq "$label/runner-API_TOKEN" "$runner_val" "$expected_runner"
  assert_eq "$label/runnermanager-API_KEY" "$manager_val" "$expected_manager"

  rm -f "$out"
}

echo "=== Runner Auth Contract: charts/daytona ==="
run_scenario "S1 default render" "" "secret_api_token" "secret_api_token" "secret_api_token"
echo
run_scenario "S2 single source (runner token)" "--set services.runner.env.API_TOKEN=alpha-token" "alpha-token" "alpha-token" "alpha-token"
echo
run_scenario "S3 explicit decouple" "--set services.api.env.DEFAULT_RUNNER_API_KEY=beta-api --set services.runner.env.API_TOKEN=gamma-runner" "beta-api" "gamma-runner" "gamma-runner"
echo
run_scenario "S4 explicit manager override" "--set services.runner.env.API_TOKEN=alpha-token --set services.runnermanager.env.API_KEY=delta-manager" "alpha-token" "alpha-token" "delta-manager"
echo

if [[ "$FAIL" -eq 0 ]]; then
  echo "OK: auth contract satisfied across all scenarios"
else
  echo "REGRESSION: auth contract failed"
fi
exit "$FAIL"
