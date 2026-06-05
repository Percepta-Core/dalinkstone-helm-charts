# Legacy Azure BYOC reproducer

> **⚠️ DO NOT USE FOR NEW DEPLOYMENTS.** Use [`../up.sh`](../up.sh) instead.

This directory contains the original `install.sh`-on-Azure-VM reproducer. It bootstraps a Daytona runner directly on a VM via SSH/`az vm run-command`, which is the LEGACY bare-metal path that pre-dates the Kubernetes-native Helm chart.

Kept here for forensic comparison while the [upstream IRSA support gap](../../../docs/upstream-issues/runner-irsa-support.md) is open. Will be removed entirely in Prompt 2.

| File | Purpose |
|---|---|
| `repro.sh` | Full legacy provisioner: AKS + Cloudflare DNS + cert-manager + Azure Storage + rclone-s3-gateway + Azure VM runner + install.sh bootstrap |
| `runner-bootstrap.sh` | VM-side script that downloads and runs `install.sh` on each Azure VM runner |

The canonical K8s-native path is `bash ../up.sh` — see [`../README.md`](../README.md) and `/Users/dalinstone/main/test/byoc-overhaul/azure.md`.
