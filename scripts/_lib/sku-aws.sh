#!/usr/bin/env bash
# scripts/_lib/sku-aws.sh — quota-aware AWS EC2 instance type selection.
# Sourced by scripts/aws-setup/up.sh.
#
# Requires: aws, jq, awk; STATE_DIR var; sku-data.sh and common.sh sourced first.

# omc::aws_select_instance_type REGION REQUIRED_VCPU [override_var=OMC_INSTANCE_TYPE]
#
# Picks an EC2 instance type that:
#   1. is offered in REGION (describe-instance-type-offerings)
#   2. is in the OMC_AWS_FAMILIES allowlist (x86_64 only)
#   3. has VCpuInfo.DefaultVCpus >= REQUIRED_VCPU
#   4. fits within the Standard On-Demand vCPU quota (L-1216C47A) headroom
#
# Outputs the chosen instance type name to STDOUT. Menu + logs go to STDERR.
# The L-1216C47A quota covers all (a,c,d,h,i,m,r,t,z) family vCPUs combined;
# "used" is approximated by counting running instances in matching families.
omc::aws_select_instance_type() {
  local region="$1" required_vcpu="$2" override_var="${3:-OMC_INSTANCE_TYPE}"
  omc::need_cmd aws jq awk
  local cache="$STATE_DIR/skus-aws-$region.json"

  local offerings
  offerings="$(aws ec2 describe-instance-type-offerings \
    --location-type region --region "$region" \
    --filters "Name=location,Values=$region" \
    --query 'InstanceTypeOfferings[].InstanceType' --output json 2>/dev/null)" \
    || omc::die "aws ec2 describe-instance-type-offerings failed for $region (check aws credentials / region)"

  local fam_filter
  fam_filter="$(printf '%s' "$OMC_AWS_FAMILIES" | tr ' ' '|')"
  local candidates
  candidates="$(jq -r --arg f "^($fam_filter)\\." \
    '.[] | select(test($f))' <<< "$offerings" | sort -u)"

  if [[ -z "$candidates" ]]; then
    omc::die "No AWS instance types in $region match family allowlist ($OMC_AWS_FAMILIES). Check region or update scripts/_lib/sku-data.sh."
  fi

  if ! omc::cache_fresh "$cache" 15; then
    local batch
    batch="$(printf '%s\n' "$candidates" | head -n 100 | tr '\n' ' ')"
    # shellcheck disable=SC2086
    aws ec2 describe-instance-types --region "$region" \
      --instance-types $batch \
      --query 'InstanceTypes[].{name:InstanceType,vcpu:VCpuInfo.DefaultVCpus,mem:MemoryInfo.SizeInMiB,arch:ProcessorInfo.SupportedArchitectures}' \
      --output json > "$cache" \
      || omc::die "aws ec2 describe-instance-types failed for $region"
  fi

  local quota_limit quota_used
  quota_limit="$(aws service-quotas get-service-quota \
    --service-code ec2 --quota-code L-1216C47A \
    --region "$region" --query 'Quota.Value' --output text 2>/dev/null || echo 0)"
  quota_used="$(aws ec2 describe-instances --region "$region" \
    --filters 'Name=instance-state-name,Values=running' \
    --query 'Reservations[].Instances[].InstanceType' --output text 2>/dev/null \
    | tr '[:space:]' '\n' \
    | awk 'BEGIN{c=0} /^[acdhimrtz][0-9]/ {n=split($0,p,"."); if(n>=2){c+=1}} END{print c}')"

  local viable ranks_json
  ranks_json="$(_omc_aws_ranks_json)"
  viable="$(jq -r --argjson req "$required_vcpu" --argjson ranks "$ranks_json" '
    map(
      . + {family: (.name | split(".") | .[0])}
    ) |
    map(select(.arch | index("x86_64"))) |
    map(select(.vcpu >= $req)) |
    map(. + {rank: ($ranks[.family] // 0)}) |
    map(select(.rank > 0)) |
    sort_by([-.rank, .vcpu, .name]) |
    .[0:5] |
    .[] |
    [.name, (.vcpu|tostring), ((.mem/1024)|floor|tostring), .family] | @tsv
  ' "$cache")"

  if [[ -z "$viable" ]]; then
    omc::log ERROR "Region $region has 0 viable EC2 instance types meeting $required_vcpu vCPU minimum."
    omc::log ERROR "Request a quota increase: https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-1216C47A"
    omc::die "No viable AWS instance types"
  fi

  local header tsv
  header="$(printf 'NAME\tvCPU\tMEM(GiB)\tFAMILY\tQUOTA(used/limit)')"
  tsv="$header"
  local quota_int="${quota_limit%.*}"
  while IFS=$'\t' read -r name vcpu mem family; do
    [[ -z "$name" ]] && continue
    tsv+=$'\n'"${name}"$'\t'"${vcpu}"$'\t'"${mem}"$'\t'"${family}"$'\t'"${quota_used:-0}/${quota_int:-0}"
  done <<< "$viable"

  omc::pick_from_menu "Viable EC2 instance types in $region (need >= $required_vcpu vCPU per node)" "$tsv" "$override_var"
}

_omc_aws_ranks_json() {
  local first=1 fam
  printf '{'
  for fam in $OMC_AWS_FAMILIES; do
    [[ $first -eq 0 ]] && printf ','
    printf '"%s":%s' "$fam" "$(omc::sku_rank aws "$fam")"
    first=0
  done
  printf '}'
}
