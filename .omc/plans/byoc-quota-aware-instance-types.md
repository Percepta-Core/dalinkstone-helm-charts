# Plan: Quota-aware instance type detection across 4 BYOC setup scripts + branch rename

**Owner:** PLAN agent (ultrawork extension)
**Working dir:** `/Users/dalinstone/main/fork/helm-charts`
**Working branch (current):** `ulw/p1-foundation` → renamed in W0 to `feat/byoc-k8s-native`
**No `git add` / `git commit` / `git push`.** File edits + branch rename only.

---

## 1. Decisions (locked unless operator overrides before W1)

### Decision A — Menu UX format: CONFIRMED with tweak

Use a fixed-width aligned format (not literal TSV) so the menu is human-readable in any 80-col terminal. Columns are space-padded; the helper writes the menu to STDERR and writes the **chosen SKU only** to STDOUT (so `CHOICE=$(omc::aws_select_instance_type "$AWS_REGION" 4)` works without polluting the return value).

```
Viable instance types in us-east-1 (need >= 4 vCPU available per node):

  #  NAME              vCPU   MEM   FAMILY   QUOTA(used/limit)
  1  m5.xlarge            4    16   m5       12/64
  2  m6i.xlarge           4    16   m6i       0/32
  3  m5.2xlarge           8    32   m5       12/64
  4  c6i.xlarge           4     8   c6i       4/16
  5  t3a.xlarge           4    16   t3a       0/16

Pick instance type [1-5, default 1]:
```

Rationale: TSV is machine-friendly but the operator reads this interactively. Aligned columns + a single STDOUT line is the right contract for shell composition.

### Decision B — Cache strategy: CONFIRMED

- Path: `$STATE_DIR/skus-<provider>-<region>.json` (e.g. `.state/skus-azure-eastus.json`).
- TTL: 15 min, enforced via mtime comparison (`find "$f" -mmin -15`).
- Cache only the **slow** calls: `az vm list-skus --all` (5-10s) and `aws ec2 describe-instance-types --instance-types <batch>` (varies). Quota calls (`az vm list-usage`, `aws service-quotas`, `gcloud regions describe`) are quick and re-fetched every run so the operator sees live headroom.
- macOS bash 3.2 compat: use `find -mmin` not `stat -c %Y` (BSD stat has a different flag).
- Invalidation: `rm -f "$STATE_DIR"/skus-*.json` documented in teardown / troubleshooting.

### Decision C — Non-interactive defaults: CONFIRMED with one addition

- `OMC_NONINTERACTIVE=1` (no override) → picks index `1` and logs the chosen SKU at INFO.
- `OMC_INSTANCE_TYPE=<name>` set → skip menu entirely. Validate the name is in the **viable** list (passes quota + availability). If not, `omc::die` with the viable list printed so the operator can correct.
- `OMC_INSTANCE_TYPE=<name>` + `OMC_INSTANCE_TYPE_FORCE=1` → skip validation (escape hatch for new SKUs not yet in the family rank table). Logs WARN.
- Cached chosen SKU: persist to `$STATE_DIR/prompts.env` as `AWS_NODE_VM_SIZE` / `AZURE_NODE_VM_SIZE` / `GCP_NODE_MACHINE_TYPE` so re-runs are idempotent (existing pattern).

### Decision D — Family allowlist: CONFIRMED, with arch filter

| Cloud | Allowlist | Arch filter |
|---|---|---|
| AWS  | `m5 m6i m7i c5 c6i c7i t3 t3a` | `x86_64` only (chart uses noble amd64 .debs) |
| Azure | `D-series v3/v4/v5/v6` (Dsv3, Dsv4, Dsv5, Dasv4, Dasv5, Dadsv5, Dsv6) + `B-series` (Bs) | exclude `architectureTypes` containing `Arm64` |
| GCP | `e2 n2 c3` | implicit (all are x86_64) |

Family rank table (higher = preferred, used as jq secondary sort):

```
AWS:    m7i=70 c7i=69 m6i=60 c6i=59 m5=50 c5=49 t3a=30 t3=29
Azure:  Dsv6=70 Dsv5=60 Dasv5=58 Dadsv5=56 Dsv4=50 Dasv4=48 Dsv3=40 Bs=20
GCP:    c3=60 n2=50 e2=40
```

Codified in `_lib/sku-data.sh` so each provider helper sources one source of truth.

### Decision E — Node count strategy: CONFIRMED, with quota math made explicit

Per-pool quota check = `node_count * vCPU_per_node`. Total quota check = sum across pools sharing a quota.

| Cloud | System pool | Sandbox pool | Quota math per pool |
|---|---|---|---|
| AWS  | n/a (single managed NG named `sandbox`) | 1 node default, max 3 | sandbox: `vCPU * 1` headroom, `vCPU * 3` for autoscale headroom (warn-only if <max) |
| Azure | 2 nodes | 1 node | system: `vCPU * 2`, sandbox: `vCPU * 1`, **summed per family** since AKS allows different SKUs but here we use the same SKU for both pools so total = `vCPU * 3` |
| Azure OSS | 3 nodes | 1 node | total = `vCPU * 4` |
| GCP | 1 node per zone | 1 node per zone | regional cluster → multiply by zone count (typically 3) → total = `vCPU * 6` per family-CPUS quota |

Hard threshold: SKU is **viable** only if `quota_available >= node_count * vCPU` for the **required** node count (not max). Autoscale headroom is informational only.

GCP nuance: `--num-nodes` is per-zone for regional clusters. Helper multiplies by the live zone count from `gcloud compute regions describe`.

### Decision F — Branch rename timing: BEFORE refactor (CONFIRMED)

Rename in W0. All subsequent file edits live on `feat/byoc-k8s-native`. Rationale: rename is local + safe (no remote tracking change since operator forbids push), and we want the refactor diff attributed to the conventional name from the start.

Rename command (W0.1 only):

```bash
git branch -m ulw/p1-foundation feat/byoc-k8s-native
# Verify
git branch --show-current   # → feat/byoc-k8s-native
```

If `feat/byoc-k8s-native` already exists locally (collision), implementer halts and asks the operator (logged in open-questions).

---

## 2. Wave-ordered breakdown

Total: 7 waves. Each wave has parallel groups noted. TDD discipline: shellcheck/bash-n run after every file edit; helm-unittest + helm lint + check-helm-values-templates run as full sweep at end of W6.

### Wave 0 — Branch rename + plan persistence (sequential, ~2 min)

- **W0.1** Rename branch.
  - WHERE: working tree.
  - WHY: S4-BRANCH-RENAME.
  - HOW: `git branch -m ulw/p1-foundation feat/byoc-k8s-native`. Confirm with `git branch --show-current`.
  - VERIFY: `git branch --show-current` returns `feat/byoc-k8s-native`; `git status -s` unchanged from before rename; uncommitted edits intact.
- **W0.2** Sanity-check static gates baseline (GREEN snapshot to compare against).
  - WHERE: repo root.
  - WHY: confirm Prompt 1 GREEN state is the actual starting point before any helper changes.
  - HOW: `bash hack/check-scripts.sh && bash hack/check-helm-values-templates.sh && bash hack/check-baseline-compat.sh && (cd charts/daytona && helm lint) && (cd charts/daytona-region && helm lint) && helm unittest charts/daytona && helm unittest charts/daytona-region`.
  - VERIFY: all GREEN (record exit codes, log to `.omc/state/byoc-quota/baseline.log`).

### Wave 1 — Shared SKU library scaffold (sequential — foundation for W2/W3/W4)

- **W1.1** Create `scripts/_lib/sku-data.sh` with family rank tables + allowlists.
  - WHERE: `scripts/_lib/sku-data.sh` (new).
  - WHY: single source of truth for D — used by 3 provider helpers.
  - HOW:

    ```bash
    #!/usr/bin/env bash
    # scripts/_lib/sku-data.sh — family allowlists + rank tables.
    # Sourced by sku-aws.sh, sku-azure.sh, sku-gcp.sh.

    # space-separated for bash 3.2 compat (no declare -A)
    OMC_AWS_FAMILIES="m5 m6i m7i c5 c6i c7i t3 t3a"
    OMC_AZURE_FAMILY_PREFIXES="standardDSv6Family standardDSv5Family standardDASv5Family standardDADSv5Family standardDSv4Family standardDASv4Family standardDSv3Family standardBsFamily"
    OMC_GCP_FAMILIES="e2 n2 c3"

    # rank lookup: omc::sku_rank <cloud> <family> -> integer (higher = better)
    omc::sku_rank() {
      local cloud="$1" family="$2"
      case "$cloud:$family" in
        aws:m7i) echo 70 ;;
        aws:c7i) echo 69 ;;
        aws:m6i) echo 60 ;;
        aws:c6i) echo 59 ;;
        aws:m5)  echo 50 ;;
        aws:c5)  echo 49 ;;
        aws:t3a) echo 30 ;;
        aws:t3)  echo 29 ;;
        azure:standardDSv6Family)   echo 70 ;;
        azure:standardDSv5Family)   echo 60 ;;
        azure:standardDASv5Family)  echo 58 ;;
        azure:standardDADSv5Family) echo 56 ;;
        azure:standardDSv4Family)   echo 50 ;;
        azure:standardDASv4Family)  echo 48 ;;
        azure:standardDSv3Family)   echo 40 ;;
        azure:standardBsFamily)     echo 20 ;;
        gcp:c3) echo 60 ;;
        gcp:n2) echo 50 ;;
        gcp:e2) echo 40 ;;
        *) echo 0 ;;
      esac
    }
    ```

  - VERIFY: `bash -n scripts/_lib/sku-data.sh` and `shellcheck scripts/_lib/sku-data.sh`.

- **W1.2** Add shared menu renderer to `common.sh`.
  - WHERE: `scripts/_lib/common.sh` (append below `omc::confirm`).
  - WHY: S2-MENU-UX uniform format across providers.
  - HOW:

    ```bash
    # omc::pick_from_menu LABEL CHOICES_TSV [override_var]
    # CHOICES_TSV = newline-separated, one TSV row per choice
    # First row treated as header (rendered without index).
    # Prints CHOSEN_NAME (column 1 of selected row) to STDOUT.
    # Honors OMC_NONINTERACTIVE=1 (pick 1) and ${override_var} (skip menu, validate).
    omc::pick_from_menu() {
      local label="$1" tsv="$2" override_var="${3:-}"
      local override=""
      if [[ -n "$override_var" && -n "${!override_var:-}" ]]; then
        override="${!override_var}"
      fi
      # Split header/body
      local header body
      header="$(printf '%s\n' "$tsv" | head -n 1)"
      body="$(printf '%s\n' "$tsv" | tail -n +2)"
      local count
      count="$(printf '%s\n' "$body" | grep -c . || true)"
      if [[ "$count" -eq 0 ]]; then
        omc::die "pick_from_menu: no viable choices for '$label'"
      fi
      # Render to STDERR
      {
        printf '\n%s\n\n' "$label"
        printf '  #  '
        printf '%s\n' "$header" | awk -F'\t' '{for(i=1;i<=NF;i++) printf "%-18s", $i; print ""}'
        local i=1 line
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          printf '  %d  ' "$i"
          printf '%s\n' "$line" | awk -F'\t' '{for(i=1;i<=NF;i++) printf "%-18s", $i; print ""}'
          i=$((i + 1))
        done <<< "$body"
        printf '\n'
      } >&2
      # Override path
      if [[ -n "$override" ]]; then
        local found=""
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          if [[ "$(printf '%s' "$line" | awk -F'\t' '{print $1}')" == "$override" ]]; then
            found="$override"
            break
          fi
        done <<< "$body"
        if [[ -z "$found" ]]; then
          if [[ "${OMC_INSTANCE_TYPE_FORCE:-0}" == "1" ]]; then
            omc::log WARN "Override $override_var=$override not in viable list, forcing anyway (OMC_INSTANCE_TYPE_FORCE=1)"
            printf '%s' "$override"
            return 0
          fi
          omc::die "Override $override_var=$override is NOT in viable list above. Pick from menu or set OMC_INSTANCE_TYPE_FORCE=1 to bypass."
        fi
        omc::log INFO "Using $override_var=$override (skipping interactive menu)"
        printf '%s' "$override"
        return 0
      fi
      # Non-interactive default = pick 1
      if [[ "${OMC_NONINTERACTIVE:-0}" == "1" ]]; then
        local first
        first="$(printf '%s\n' "$body" | head -n 1 | awk -F'\t' '{print $1}')"
        omc::log INFO "Non-interactive default: $first"
        printf '%s' "$first"
        return 0
      fi
      # Interactive pick
      local pick=""
      while :; do
        read -r -p "Pick [1-$count, default 1]: " pick
        pick="${pick:-1}"
        if [[ "$pick" =~ ^[0-9]+$ ]] && [[ "$pick" -ge 1 ]] && [[ "$pick" -le "$count" ]]; then
          break
        fi
        omc::log WARN "Invalid; enter a number between 1 and $count."
      done
      local chosen
      chosen="$(printf '%s\n' "$body" | awk -v n="$pick" -F'\t' 'NR==n {print $1; exit}')"
      omc::log INFO "Selected: $chosen"
      printf '%s' "$chosen"
    }
    ```

  - VERIFY: `bash -n` + `shellcheck` on `common.sh`; manual smoke: `OMC_NONINTERACTIVE=1 bash -c 'source scripts/_lib/common.sh; omc::pick_from_menu "test" "name\tvcpu\nm5.xlarge\t4\nm5.2xlarge\t8"'` prints `m5.xlarge`.

- **W1.3** Add cache helper to `common.sh`.
  - WHERE: `scripts/_lib/common.sh` (append).
  - WHY: S3-CACHE TTL via mtime.
  - HOW:

    ```bash
    # omc::cache_fresh PATH [ttl_min=15] -> 0 if fresh, 1 if stale/missing
    omc::cache_fresh() {
      local path="$1" ttl="${2:-15}"
      [[ -f "$path" ]] || return 1
      # BSD/GNU compatible: find -mmin
      local fresh
      fresh="$(find "$path" -mmin -"$ttl" -print 2>/dev/null | head -n 1)"
      [[ -n "$fresh" ]]
    }
    ```

  - VERIFY: `bash -n` + `shellcheck`; smoke: `touch /tmp/x && omc::cache_fresh /tmp/x 15 && echo fresh`.

### Wave 2 — Provider SKU helpers (parallel within wave: W2.1, W2.2, W2.3 independent)

Each helper file lives in `scripts/_lib/` and exposes ONE entry point. Helpers source `sku-data.sh` and `common.sh`.

- **W2.1** `scripts/_lib/sku-aws.sh` — `omc::aws_select_instance_type <region> <required_vcpu> [override_env_var]`
  - WHERE: new file.
  - WHY: S1-DETECT-AWS.
  - HOW (key bash, distilled from bg_7f649f6b):

    ```bash
    omc::aws_select_instance_type() {
      local region="$1" required_vcpu="$2" override_var="${3:-OMC_INSTANCE_TYPE}"
      omc::need_cmd aws jq awk
      local cache="$STATE_DIR/skus-aws-$region.json"

      # 1) Region offerings (NOT cached — fast, account-independent)
      local offerings
      offerings="$(aws ec2 describe-instance-type-offerings \
        --location-type region --region "$region" \
        --filters "Name=location,Values=$region" \
        --query 'InstanceTypeOfferings[].InstanceType' --output json)" \
        || omc::die "aws describe-instance-type-offerings failed in $region"

      # 2) Filter to allowlist + required vCPU
      local fam_filter
      fam_filter="$(printf '%s' "$OMC_AWS_FAMILIES" | tr ' ' '|')"
      local candidates
      candidates="$(jq -r --arg f "^($fam_filter)\\." \
        '.[] | select(test($f))' <<< "$offerings" | sort -u)"

      if [[ -z "$candidates" ]]; then
        omc::die "No AWS instance types in $region match family allowlist ($OMC_AWS_FAMILIES). Check region or update _lib/sku-data.sh."
      fi

      # 3) Hydrate vCPU/mem/arch via describe-instance-types (cache)
      if ! omc::cache_fresh "$cache" 15; then
        local batch
        batch="$(printf '%s\n' "$candidates" | head -n 100 | tr '\n' ' ')"
        # shellcheck disable=SC2086
        aws ec2 describe-instance-types --region "$region" \
          --instance-types $batch \
          --query 'InstanceTypes[].{name:InstanceType,vcpu:VCpuInfo.DefaultVCpus,mem:MemoryInfo.SizeInMiB,arch:ProcessorInfo.SupportedArchitectures}' \
          --output json > "$cache" \
          || omc::die "aws describe-instance-types failed"
      fi

      # 4) Live quota (NOT cached)
      local quota_used quota_limit
      quota_limit="$(aws service-quotas get-service-quota \
        --service-code ec2 --quota-code L-1216C47A \
        --region "$region" --query 'Quota.Value' --output text 2>/dev/null || echo 0)"
      quota_used="$(aws ec2 describe-instances --region "$region" \
        --filters 'Name=instance-state-name,Values=running' \
        --query 'Reservations[].Instances[].InstanceType' --output text 2>/dev/null \
        | tr '\t' '\n' | awk '
          /^(m|c|r|t)/ { fam=substr($0,1,1); if (fam~/[mcrti]/) count++ }
          END { print count+0 }
        ')"
      # NB: quota_used is approximate; AWS does not expose live vCPU usage cleanly. Documented.

      # 5) Filter viable (vCPU >= required, x86_64, headroom OK)
      local viable
      viable="$(jq -r --argjson req "$required_vcpu" --arg ranks "$(_omc_aws_ranks_json)" '
        map(select(.arch | index("x86_64")) | select(.vcpu >= $req)) |
        map(. + {family: (.name | split(".") | .[0])}) |
        map(. + {rank: ($ranks | fromjson)[.family] // 0}) |
        sort_by([-.rank, .vcpu, .name]) |
        .[0:5] |
        .[] |
        [.name, (.vcpu|tostring), ((.mem/1024)|floor|tostring), .family] | @tsv
      ' "$cache")"

      if [[ -z "$viable" ]]; then
        omc::log ERROR "Subscription/region $region has 0 viable EC2 instance types meeting $required_vcpu vCPU."
        omc::log ERROR "Request a quota increase: https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-1216C47A"
        omc::die "No viable SKUs"
      fi

      # 6) Build menu TSV (header + body)
      local tsv
      tsv="$(printf 'NAME\tvCPU\tMEM(GiB)\tFAMILY\tQUOTA(used/limit)\n')"
      while IFS=$'\t' read -r name vcpu mem family; do
        [[ -z "$name" ]] && continue
        tsv+=$'\n'"${name}"$'\t'"${vcpu}"$'\t'"${mem}"$'\t'"${family}"$'\t'"${quota_used}/${quota_limit%.*}"
      done <<< "$viable"

      omc::pick_from_menu "Viable EC2 instance types in $region (need >= $required_vcpu vCPU)" "$tsv" "$override_var"
    }

    _omc_aws_ranks_json() {
      printf '{'
      local first=1 fam
      for fam in $OMC_AWS_FAMILIES; do
        [[ $first -eq 0 ]] && printf ','
        printf '"%s":%s' "$fam" "$(omc::sku_rank aws "$fam")"
        first=0
      done
      printf '}'
    }
    ```

  - VERIFY: `bash -n`, `shellcheck`. Smoke test with `OMC_INSTANCE_TYPE=m5.xlarge` against a mocked cache file (W6.2).

- **W2.2** `scripts/_lib/sku-azure.sh` — `omc::azure_select_vm_size <location> <required_vcpu_total> [override_env_var]`
  - WHERE: new file.
  - WHY: S1-DETECT-AZURE, S1-DETECT-OSS. Note: `required_vcpu_total` is the SUM across pools sharing the SKU (system + sandbox), so caller passes `vCPU * (system_count + sandbox_count)` — for `azure-setup` that's `vCPU*3`, for `azure-oss-setup` that's `vCPU*4`. The helper still presents per-node `vCPU >= 4` SKUs but checks quota headroom against the total.

  - HOW (key bash, distilled from bg_acac5a1c):

    ```bash
    omc::azure_select_vm_size() {
      local location="$1" required_vcpu_total="$2" override_var="${3:-OMC_INSTANCE_TYPE}"
      omc::need_cmd az jq awk
      local cache="$STATE_DIR/skus-azure-$location.json"

      # 1) SKU list (CACHED — slow 5-10s)
      if ! omc::cache_fresh "$cache" 15; then
        omc::log INFO "Fetching Azure VM SKUs for $location (5-10s, cached for 15 min)..."
        az vm list-skus -l "$location" --resource-type virtualMachines --all -o json > "$cache" \
          || omc::die "az vm list-skus failed for $location"
      fi

      # 2) Live family usage
      local usage
      usage="$(az vm list-usage --location "$location" -o json)" \
        || omc::die "az vm list-usage failed"

      # 3) Filter viable: not restricted in subscription, x86_64, vCPU >= 4 per node, family in allowlist
      # We pass the per-node minimum (4) implicitly; total-vCPU check is against the family quota
      local fam_filter
      fam_filter="$(printf '%s' "$OMC_AZURE_FAMILY_PREFIXES" | tr ' ' '|')"

      local viable
      viable="$(jq -r --arg fams "$fam_filter" --argjson req_total "$required_vcpu_total" --argjson ranks "$(_omc_azure_ranks_json)" --argjson usage "$usage" '
        # index usage by family name
        ($usage | map({key: .name.value, value: {used: .currentValue, limit: .limit}}) | from_entries) as $u |
        map(
          select(.resourceType == "virtualMachines")
          | select(.locations | index($location // ""))
          | select(.family | test($fams))
          | select([.restrictions[]?.reasonCode] | index("NotAvailableForSubscription") | not)
          | select([.capabilities[]? | select(.name=="HyperVGenerations") | .value] | join(",") | test("V2"))
          | select([.capabilities[]? | select(.name=="CpuArchitectureType") | .value] | join(",") | test("Arm64") | not)
          | . + {
              vcpu: ([.capabilities[]? | select(.name=="vCPUs") | .value][0] | tonumber? // 0),
              memgb: ([.capabilities[]? | select(.name=="MemoryGB") | .value][0] | tonumber? // 0),
              rank: ($ranks[.family] // 0),
              quota_used: ($u[.family].used // 0),
              quota_limit: ($u[.family].limit // 0)
            }
          | select(.vcpu >= 4)
          | select((.quota_limit - .quota_used) >= $req_total)
        ) |
        sort_by([-.rank, .vcpu, .name]) |
        .[0:5] |
        .[] |
        [.name, (.vcpu|tostring), (.memgb|tostring), .family, "\(.quota_used)/\(.quota_limit)"] | @tsv
      ' "$cache")"

      if [[ -z "$viable" ]]; then
        omc::log ERROR "Azure subscription has 0 viable VM SKUs in $location with $required_vcpu_total vCPU headroom."
        omc::log ERROR "Check restrictions: az vm list-skus -l $location --all --query \"[?restrictions]\""
        omc::log ERROR "Quota: https://learn.microsoft.com/en-us/azure/quotas/quickstart-increase-quota-portal"
        omc::die "No viable SKUs"
      fi

      local header="NAME\tvCPU\tMEM(GiB)\tFAMILY\tQUOTA(used/limit)"
      local tsv
      tsv="$(printf '%b\n%s\n' "$header" "$viable")"
      omc::pick_from_menu "Viable AKS VM SKUs in $location (need >= $required_vcpu_total vCPU total headroom)" "$tsv" "$override_var"
    }

    _omc_azure_ranks_json() {
      printf '{'
      local first=1 fam
      for fam in $OMC_AZURE_FAMILY_PREFIXES; do
        [[ $first -eq 0 ]] && printf ','
        printf '"%s":%s' "$fam" "$(omc::sku_rank azure "$fam")"
        first=0
      done
      printf '}'
    }
    ```

  - VERIFY: `bash -n`, `shellcheck`. Note: the `$location` capture in jq is a self-reference — adjust to inject via `--arg loc "$location"` if jq complains; W6.2 catches this.

- **W2.3** `scripts/_lib/sku-gcp.sh` — `omc::gcp_select_machine_type <region> <required_vcpu_total> [override_env_var]`
  - WHERE: new file.
  - WHY: S1-DETECT-GCP.
  - HOW (distilled from bg_f2d3ca6e):

    ```bash
    omc::gcp_select_machine_type() {
      local region="$1" required_vcpu_total="$2" override_var="${3:-OMC_INSTANCE_TYPE}"
      omc::need_cmd gcloud jq awk
      local cache="$STATE_DIR/skus-gcp-$region.json"

      # zone count for regional cluster math
      local zones zone_count
      zones="$(gcloud compute regions describe "$region" --format=json)" \
        || omc::die "gcloud compute regions describe failed"
      zone_count="$(jq '.zones | length' <<< "$zones")"
      omc::log INFO "GCP region $region has $zone_count zones; regional cluster multiplies node count accordingly."

      # quotas per family-CPUS metric
      local q_e2 q_n2 q_c3
      q_e2="$(jq -r '.quotas[] | select(.metric=="CPUS")     | "\(.usage|tostring)/\(.limit|tostring)"' <<< "$zones")"
      q_n2="$(jq -r '.quotas[] | select(.metric=="N2_CPUS")  | "\(.usage|tostring)/\(.limit|tostring)"' <<< "$zones")"
      q_c3="$(jq -r '.quotas[] | select(.metric=="C3_CPUS")  | "\(.usage|tostring)/\(.limit|tostring)"' <<< "$zones")"

      # machine types (cached)
      if ! omc::cache_fresh "$cache" 15; then
        local zone_list
        zone_list="$(jq -r '.zones[]' <<< "$zones" | sed 's|.*/||' | tr '\n' ',' | sed 's/,$//')"
        gcloud compute machine-types list --zones="$zone_list" --format=json > "$cache" \
          || omc::die "gcloud compute machine-types list failed"
      fi

      # filter + dedup by name (machine types repeat across zones)
      local viable
      viable="$(jq -r --argjson req "$required_vcpu_total" \
        --arg qe2 "$q_e2" --arg qn2 "$q_n2" --arg qc3 "$q_c3" '
        unique_by(.name) |
        map(. + {family: (.name | split("-") | .[0])}) |
        map(select(.family == "e2" or .family == "n2" or .family == "c3")) |
        map(select(.guestCpus >= 4)) |
        map(. + {rank: (if .family=="c3" then 60 elif .family=="n2" then 50 else 40 end)}) |
        map(. + {quota: (if .family=="c3" then $qc3 elif .family=="n2" then $qn2 else $qe2 end)}) |
        # crude headroom: parse "used/limit", check (limit-used) >= req
        map(. + {
          used:  (.quota | split("/")[0] | tonumber? // 0),
          limit: (.quota | split("/")[1] | tonumber? // 0)
        }) |
        map(select((.limit - .used) >= $req)) |
        sort_by([-.rank, .guestCpus, .name]) |
        .[0:5] |
        .[] |
        [.name, (.guestCpus|tostring), ((.memoryMb/1024)|floor|tostring), .family, .quota] | @tsv
      ' "$cache")"

      if [[ -z "$viable" ]]; then
        omc::log ERROR "GCP region $region has 0 viable machine types with $required_vcpu_total vCPU headroom."
        omc::log ERROR "Quota: https://console.cloud.google.com/iam-admin/quotas?service=compute.googleapis.com"
        omc::die "No viable SKUs"
      fi

      local header="NAME\tvCPU\tMEM(GiB)\tFAMILY\tQUOTA(used/limit)"
      local tsv
      tsv="$(printf '%b\n%s\n' "$header" "$viable")"
      omc::pick_from_menu "Viable GKE machine types in $region (need >= $required_vcpu_total vCPU total)" "$tsv" "$override_var"
    }
    ```

  - VERIFY: `bash -n`, `shellcheck`.

### Wave 3 — Wire each up.sh to source helpers + call selector (parallel: W3.1, W3.2, W3.3, W3.4)

Each up.sh gets:
1. One new `source` line after the existing `source scripts/_lib/common.sh`.
2. New block AFTER `chmod 600 "$PROMPTS_FILE"` and BEFORE the cluster create — calls the selector, persists the chosen SKU to `prompts.env`.
3. Hardcoded SKU replaced with the chosen variable.

- **W3.1** `scripts/aws-setup/up.sh` (line 98)
  - WHERE: after `chmod 600 "$PROMPTS_FILE"` (~line 73); SKU replace at line 98.
  - HOW:
    ```bash
    # === 2.5 Quota-aware instance type selection =================================
    source "$SCRIPT_DIR/../_lib/sku-data.sh"
    source "$SCRIPT_DIR/../_lib/sku-aws.sh"
    : "${AWS_NODE_VM_SIZE:=}"  # may be pre-set via prompts.env
    if [[ -z "$AWS_NODE_VM_SIZE" ]]; then
      AWS_NODE_VM_SIZE="$(omc::aws_select_instance_type "$AWS_REGION" 4 OMC_INSTANCE_TYPE)"
      echo "AWS_NODE_VM_SIZE=$AWS_NODE_VM_SIZE" >> "$PROMPTS_FILE"
    fi
    omc::log INFO "Using AWS instance type: $AWS_NODE_VM_SIZE"
    ```
  - Line 98: `instanceType: m5.xlarge` → `instanceType: ${AWS_NODE_VM_SIZE}`
  - VERIFY: `bash -n scripts/aws-setup/up.sh`; `shellcheck scripts/aws-setup/up.sh`; grep confirms zero literal `m5.xlarge`.

- **W3.2** `scripts/azure-setup/up.sh` (lines 105 + 119)
  - WHY: same SKU shared by system (count=2) + sandbox (count=1) pools → total vCPU headroom needed = `4 * 3 = 12`.
  - HOW: after `chmod 600 "$PROMPTS_FILE"`:
    ```bash
    source "$SCRIPT_DIR/../_lib/sku-data.sh"
    source "$SCRIPT_DIR/../_lib/sku-azure.sh"
    : "${AZURE_NODE_VM_SIZE:=}"
    if [[ -z "$AZURE_NODE_VM_SIZE" ]]; then
      # 2 system + 1 sandbox node, each needs >= 4 vCPU; family quota check uses sum
      AZURE_NODE_VM_SIZE="$(omc::azure_select_vm_size "$AZURE_LOCATION" 12 OMC_INSTANCE_TYPE)"
      echo "AZURE_NODE_VM_SIZE=$AZURE_NODE_VM_SIZE" >> "$PROMPTS_FILE"
    fi
    omc::log INFO "Using Azure VM size: $AZURE_NODE_VM_SIZE"
    ```
  - Lines 105 + 119: `Standard_D4s_v5` → `${AZURE_NODE_VM_SIZE}` (both).
  - VERIFY: `bash -n`; `shellcheck`; grep confirms zero literal `Standard_D4s_v5`.

- **W3.3** `scripts/gcs-setup/up.sh` (lines 85 + 100)
  - WHY: system (1 node/zone) + sandbox (1 node/zone) → 2 nodes/zone × ~3 zones × 4 vCPU = 24 vCPU total per CPUS-family quota.
  - HOW: after `chmod 600 "$PROMPTS_FILE"`:
    ```bash
    source "$SCRIPT_DIR/../_lib/sku-data.sh"
    source "$SCRIPT_DIR/../_lib/sku-gcp.sh"
    : "${GCP_NODE_MACHINE_TYPE:=}"
    if [[ -z "$GCP_NODE_MACHINE_TYPE" ]]; then
      GCP_NODE_MACHINE_TYPE="$(omc::gcp_select_machine_type "$GCP_REGION" 24 OMC_INSTANCE_TYPE)"
      echo "GCP_NODE_MACHINE_TYPE=$GCP_NODE_MACHINE_TYPE" >> "$PROMPTS_FILE"
    fi
    omc::log INFO "Using GCP machine type: $GCP_NODE_MACHINE_TYPE"
    ```
  - Lines 85 + 100: `e2-standard-4` → `${GCP_NODE_MACHINE_TYPE}`.
  - VERIFY: `bash -n`; `shellcheck`; grep confirms zero literal `e2-standard-4`.

- **W3.4** `scripts/azure-oss-setup/up.sh` (lines 123 + 135)
  - WHY: 3 system + 1 sandbox → `4 * 4 = 16` vCPU total.
  - HOW: after `chmod 600 "$PROMPTS_FILE"`:
    ```bash
    source "$SCRIPT_DIR/../_lib/sku-data.sh"
    source "$SCRIPT_DIR/../_lib/sku-azure.sh"
    : "${AZURE_NODE_VM_SIZE:=}"
    if [[ -z "$AZURE_NODE_VM_SIZE" ]]; then
      AZURE_NODE_VM_SIZE="$(omc::azure_select_vm_size "$AZURE_LOCATION" 16 OMC_INSTANCE_TYPE)"
      echo "AZURE_NODE_VM_SIZE=$AZURE_NODE_VM_SIZE" >> "$PROMPTS_FILE"
    fi
    omc::log INFO "Using Azure VM size: $AZURE_NODE_VM_SIZE"
    ```
  - Lines 123 + 135: `Standard_D4s_v5` → `${AZURE_NODE_VM_SIZE}`.
  - VERIFY: `bash -n`; `shellcheck`; grep confirms zero literal `Standard_D4s_v5`.

### Wave 4 — Negative-path + cache verification (sequential, ~10 min)

- **W4.1** Verify S6-NEGATIVE: simulate "zero viable SKUs" by overriding `_omc_aws_ranks_json` to empty and confirming `omc::die` fires.
  - WHERE: ad-hoc smoke shell, not committed.
  - HOW: `OMC_NONINTERACTIVE=1 STATE_DIR=/tmp/x mkdir -p /tmp/x; echo '[]' > /tmp/x/skus-aws-us-east-1.json; ...` — confirm exit code != 0 and the "Request a quota increase" line appears in stderr.
  - VERIFY: exit code 1; error message contains the documented URL.

- **W4.2** Verify S3-CACHE: touch `$STATE_DIR/skus-azure-eastus.json` and re-run with a stubbed `az` that records call count.
  - HOW: shim `az()` in a subshell to count invocations; first call writes cache, second call reads cache (zero `az vm list-skus` calls in the second run within 15 min).
  - VERIFY: second-run `az vm list-skus` invocation count = 0.

- **W4.3** Verify S2-MENU-UX with `OMC_INSTANCE_TYPE=<viable>`:
  - HOW: prepare a hand-crafted cache file with 5 known SKUs; call `omc::aws_select_instance_type us-east-1 4 OMC_INSTANCE_TYPE` with `OMC_INSTANCE_TYPE=m5.xlarge`; stdout should be exactly `m5.xlarge`.
  - VERIFY: stdout = `m5.xlarge`, no menu printed.

- **W4.4** Verify override validation: `OMC_INSTANCE_TYPE=garbage.bogus` → `omc::die` unless `OMC_INSTANCE_TYPE_FORCE=1`.

### Wave 5 — Reviewer gate (MANDATORY, blocking)

- **W5.1** Spawn `code-reviewer` (opus) on the diff of: `scripts/_lib/sku-data.sh`, `scripts/_lib/sku-aws.sh`, `scripts/_lib/sku-azure.sh`, `scripts/_lib/sku-gcp.sh`, the 5 lines added to `scripts/_lib/common.sh`, and the 4 up.sh patches.
  - Prompt the reviewer to specifically check: (a) jq self-references that may break (Azure helper `$location`), (b) bash 3.2 compat (no `mapfile`, no `declare -A`), (c) STDERR vs STDOUT discipline (only chosen SKU on STDOUT), (d) error-path coverage for "zero viable", (e) cache TTL race conditions, (f) shellcheck silenced disables are justified, (g) selector contract `daytona-sandbox-c=true` + `sandbox=true:NoSchedule` preserved in all 4 scripts.
- **W5.2** Address reviewer findings. If material, loop W2/W3/W4 for affected files.
- **W5.3** Re-run reviewer until PASS.

### Wave 6 — Full static gate sweep (sequential, blocking)

- **W6.1** `bash hack/check-scripts.sh` (shellcheck + bash -n on all scripts/**).
- **W6.2** `bash hack/check-helm-values-templates.sh` (must stay GREEN; no chart changes expected).
- **W6.3** `bash hack/check-baseline-compat.sh`.
- **W6.4** `(cd charts/daytona && helm lint && helm unittest .)`.
- **W6.5** `(cd charts/daytona-region && helm lint && helm unittest .)`.
- **W6.6** Grep audit:
  - `grep -nE 'Standard_D[0-9]|e2-standard-4|m5\.xlarge' scripts/**/up.sh` → MUST be empty.
  - `grep -n 'daytona-sandbox-c=true' scripts/**/up.sh` → MUST exist in all 4 scripts (selector preserved).
  - `grep -n 'sandbox=true:NoSchedule' scripts/**/up.sh` → MUST exist in all 4 scripts (taint preserved).
- **W6.7** Compare against `baseline.log` from W0.2: all gates that were GREEN remain GREEN.

### Wave 7 — Final summary + handoff (no commits)

- **W7.1** Write `.omc/state/byoc-quota/summary.md` with: files touched, lines changed, gates passed, baseline-vs-final diff snippet.
- **W7.2** Print branch name (`feat/byoc-k8s-native`) and uncommitted diff stat: `git diff --stat`. Operator decides commit cadence.

---

## 3. Parallel groupings

- **Within W2:** W2.1 (AWS), W2.2 (Azure), W2.3 (GCP) — fully parallel (3 new files, no shared edits).
- **Within W3:** W3.1, W3.2, W3.3, W3.4 — fully parallel (4 different up.sh files).
- **Within W4:** W4.1, W4.2, W4.3, W4.4 — parallel.
- **Within W6:** static checks are independent; group W6.1-W6.5 as parallel background runs.
- Everything else is sequential.

---

## 4. TDD checkpoints

| Wave | TDD posture | Justification |
|---|---|---|
| W0  | Snapshot baseline gates | Establishes GREEN starting line |
| W1  | `bash -n` + `shellcheck` per file | Static check is the test for shared helpers; no behavioural test possible without real cloud calls |
| W2  | `bash -n` + `shellcheck` per file; mock-cache smoke | Documented TDD exemption: cloud SDK calls cannot be unit-tested in this repo without introducing a mocking framework outside this PR's scope |
| W3  | `bash -n` + `shellcheck`; grep audit for literal SKUs gone | Mechanical wiring + literal removal is statically verifiable |
| W4  | Mock-cache scenario tests | Negative path + cache + override coverage via stub `az`/`aws`/`gcloud` in subshell |
| W5  | Reviewer gate | Catches semantic gaps W4 can't |
| W6  | Full static gate sweep | Final regression boundary |

**Exemption recorded:** Real cloud calls are NOT testable in CI without a mocking layer; compensating controls are (a) shellcheck warning-clean, (b) bash -n parse, (c) W4 mock-cache smoke tests, (d) W5 reviewer gate, (e) W6 full static sweep against baseline. The implementer must NOT execute real `aws`/`az`/`gcloud` commands — the operator owns that pass.

---

## 5. Verification gates between waves

- After W0 → W1: baseline.log shows all 6 gates GREEN.
- After W1 → W2: `bash -n` clean on `common.sh`, `sku-data.sh`; manual menu smoke prints expected output.
- After W2 → W3: `bash -n` clean on 3 new files; mock-cache smoke returns chosen SKU on STDOUT.
- After W3 → W4: 4 up.sh files parse + shellcheck clean; literal SKU grep is empty.
- After W4 → W5: W4.1-W4.4 all pass; helpers exit non-zero on negative cases.
- After W5 → W6: reviewer PASS verdict logged.
- After W6 → W7: all 6 baseline gates GREEN; literal-SKU grep empty; selector + taint greps non-empty across 4 scripts.

---

## 6. Reviewer gate placement

Reviewer (`code-reviewer` opus, per Prompt 1 pattern) runs at **W5**, AFTER all helper code lands and AFTER W4 mock smoke passes, BEFORE the W6 full sweep. Single reviewer pass; if it fails materially, loop W2/W3/W4 for the affected files. Do NOT skip the gate even if W6 would pass — semantic issues (e.g. jq self-reference, cache race) won't show up in helm-unittest.

---

## 7. Implementer's TODO list

```
.omc/plans/open-questions.md: append rename-collision branch — verify by file exists with W0 entry
W0.1  git branch -m: rename ulw/p1-foundation → feat/byoc-k8s-native — verify by git branch --show-current
W0.2  hack/check-*.sh + helm lint/unittest: snapshot baseline — verify by .omc/state/byoc-quota/baseline.log shows 6 GREEN

W1.1  scripts/_lib/sku-data.sh: create family allowlists + omc::sku_rank — verify by shellcheck + bash -n
W1.2  scripts/_lib/common.sh: append omc::pick_from_menu — verify by shellcheck + smoke OMC_NONINTERACTIVE=1 returns line 1
W1.3  scripts/_lib/common.sh: append omc::cache_fresh — verify by shellcheck + smoke fresh-vs-stale

W2.1  scripts/_lib/sku-aws.sh: create omc::aws_select_instance_type for S1-DETECT-AWS — verify by shellcheck + bash -n
W2.2  scripts/_lib/sku-azure.sh: create omc::azure_select_vm_size for S1-DETECT-AZURE/OSS — verify by shellcheck + bash -n
W2.3  scripts/_lib/sku-gcp.sh: create omc::gcp_select_machine_type for S1-DETECT-GCP — verify by shellcheck + bash -n

W3.1  scripts/aws-setup/up.sh (line 73 + 98): source helpers + replace m5.xlarge for S1-DETECT-AWS — verify by grep -n m5.xlarge returns empty + bash -n
W3.2  scripts/azure-setup/up.sh (line 73 + 105/119): source helpers + replace Standard_D4s_v5 for S1-DETECT-AZURE — verify by grep + bash -n
W3.3  scripts/gcs-setup/up.sh (line 70 + 85/100): source helpers + replace e2-standard-4 for S1-DETECT-GCP — verify by grep + bash -n
W3.4  scripts/azure-oss-setup/up.sh (line 73 + 123/135): source helpers + replace Standard_D4s_v5 for S1-DETECT-OSS — verify by grep + bash -n

W4.1  mock-stub: empty viable list triggers omc::die for S6-NEGATIVE — verify by exit code 1 + quota URL in stderr
W4.2  mock-stub: 2nd run within 15min skips az vm list-skus for S3-CACHE — verify by stub call count = 0
W4.3  OMC_INSTANCE_TYPE=m5.xlarge skips menu for S2-MENU-UX — verify by stdout == "m5.xlarge"
W4.4  OMC_INSTANCE_TYPE=garbage triggers omc::die for S2-MENU-UX validation — verify by exit 1 unless OMC_INSTANCE_TYPE_FORCE=1

W5.1  Spawn code-reviewer opus on full diff — verify by reviewer PASS verdict
W5.2  Address reviewer findings if any — verify by re-reviewer PASS

W6.1  hack/check-scripts.sh — verify by exit 0
W6.2  hack/check-helm-values-templates.sh — verify by exit 0
W6.3  hack/check-baseline-compat.sh — verify by exit 0
W6.4  charts/daytona helm lint + unittest — verify by 16/16 + lint clean
W6.5  charts/daytona-region helm lint + unittest — verify by same
W6.6  grep audit: literal SKUs gone, selectors+taints preserved — verify by 0 literal hits, 4 selector hits, 4 taint hits
W6.7  Diff vs baseline.log — verify by no regression

W7.1  .omc/state/byoc-quota/summary.md: write summary — verify by file exists
W7.2  Print git diff --stat + branch name — verify by output captured to summary
```

---

## 8. Test fixtures (TDD exemption documented)

The repo has no SDK mocking framework, and the new helpers cannot be unit-tested without real cloud calls.

**Compensating controls (binding):**

1. **Static**: `shellcheck` warning-clean on all new/edited files; `bash -n` parse clean.
2. **Mock smoke (W4)**: stub `aws`/`az`/`gcloud` as shell functions in a subshell, write fixture JSON to `$STATE_DIR`, exercise:
   - happy path → chosen SKU printed to STDOUT.
   - empty viable → exit 1 with quota URL in STDERR.
   - cache hit (2nd run) → zero SDK calls.
   - override valid → bypass menu.
   - override invalid → die unless FORCE=1.
3. **Static gates (W6)**: existing helm-unittest 16/16 + helm lint 3/3 + check-helm-values-templates + check-scripts + check-baseline-compat. All must stay GREEN against baseline.
4. **Reviewer (W5)**: code-reviewer opus catches semantic issues mock smoke can't.
5. **Operator end-to-end**: operator runs against real subscriptions. The implementer does NOT.

**Fixture files** (created in `/tmp/byoc-mock-state/` during W4, NOT committed):

- `skus-aws-us-east-1.json` — 5 instance type records with mixed families.
- `skus-azure-eastus.json` — 5 VM SKU records, some with `NotAvailableForSubscription` restriction.
- `skus-gcp-us-central1.json` — 5 machine type records across e2/n2/c3.
- `usage-azure-eastus.json` — usage records covering each SKU's family.

---

## 9. Open questions (persisted to `.omc/plans/open-questions.md`)

- Branch rename collision: what if `feat/byoc-k8s-native` already exists locally?
- AWS quota_used computation is approximate (parses running-instance families); is the approximation acceptable, or should we use Trusted Advisor / Cost Explorer? — Defer.
- Should the menu include a `[6] enter a custom SKU` escape hatch alongside `OMC_INSTANCE_TYPE_FORCE`? — Defer; current design treats env override as the escape hatch.
- The cache invalidation is purely time-based (15 min); should we also invalidate on `--region` change? — Already handled: cache path includes region.
```
