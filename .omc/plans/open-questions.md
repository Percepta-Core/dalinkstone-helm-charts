# Open Questions

## byoc-quota-aware-instance-types — 2026-06-04

- [ ] Branch rename collision: what if `feat/byoc-k8s-native` already exists locally? — Implementer must halt at W0.1 and ask the operator for an alternative name before proceeding.
- [ ] AWS `quota_used` is approximated by counting running instance families via `aws ec2 describe-instances`; AWS does not cleanly expose live vCPU consumption per quota. Acceptable, or upgrade to Trusted Advisor / Cost Explorer integration? — Defer; documented as approximate in helper output.
- [ ] Should the menu add an explicit `[6] enter a custom SKU` option alongside the `OMC_INSTANCE_TYPE_FORCE=1` env escape hatch? — Defer; env override is the documented bypass.
- [ ] Azure jq filter uses `$location` self-reference inside a select() — confirm during W6.2 it parses cleanly across jq 1.6/1.7; if not, switch to `--arg loc` injection.
- [ ] Cache invalidation is purely time-based (15 min). Should re-runs with a changed cloud `$AWS_REGION` / `$AZURE_LOCATION` / `$GCP_REGION` also invalidate? — Already handled via region-suffixed cache paths.
- [ ] AWS sandbox pool has `maxSize: 3` for autoscaling; current quota check uses `required = 1 * vCPU`. Should we instead require `3 * vCPU` headroom upfront to guarantee autoscale capacity? — Defer; warn-only is acceptable for now.
