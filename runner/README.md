# Runner Installation
To install and register a Daytona Runner on your system, follow these steps:

## Prerequisites

- **Supported OS Architecture:** AMD64/x86_64
- **Docker:** The script will install Docker if not present.
- **Systemd:** Required for service management.

## Installation Steps

1. **Run the Runner Install Script**

```bash
curl -sSL https://download.daytona.io/install.sh | sudo bash
```

The script will prompt you for:
- Daytona API URL
- Daytona Admin API Key
- System resource allocation (CPU, memory, disk)
- Domain name for the runner
- Runner API URL
- Optional proxy URL, region, runner capacity, and runner API key

2. **Automatic Steps Performed by the Script**

- Checks system architecture
- Downloads the Daytona runner binary
- Installs Docker if missing
- Registers the runner with the Daytona API
- Creates and enables a systemd service for the runner
- Starts the runner service

## Managing the Runner Service

- **Check status:**
```bash
sudo systemctl status daytona-runner
```
- **View logs:**
```bash
sudo tail -f /var/log/daytona-runner.log
```
- **Stop service:**
```bash
sudo systemctl stop daytona-runner
```

For more details and troubleshooting, visit [Daytona Runner Installation Docs](https://docs.daytona.io/docs/runner/installation).

## Declarative Builder Configuration

The runner downloads declarative-builder build-context tarballs from an S3-compatible bucket. If the `AWS_*` env vars below are not set on the runner, **snapshot creation via the declarative builder will fail with an S3 access error**.

In a Customer Managed Compute (BYOC) region, the runner reads from the **same bucket** the region's snapshot-manager service writes to. Set the runner's `AWS_*` env vars to match the values configured under `services.snapshotManager.storage.s3.*` in your `daytona-region` chart.

| Runner env var (set before `install.sh`) | Must match in `daytona-region` values |
|------------------------------------------|----------------------------------------|
| `AWS_DEFAULT_BUCKET` | `services.snapshotManager.storage.s3.bucket` |
| `AWS_REGION` | `services.snapshotManager.storage.s3.region` |
| `AWS_ACCESS_KEY_ID` | `services.snapshotManager.storage.s3.accessKey` (or the IAM identity behind `existingSecret` / IRSA) |
| `AWS_SECRET_ACCESS_KEY` | `services.snapshotManager.storage.s3.secretKey` (or the IAM identity behind `existingSecret` / IRSA) |
| `AWS_ENDPOINT_URL` | `services.snapshotManager.storage.s3.endpoint` (only for non-AWS S3); default `https://s3.<region>.amazonaws.com` |

### Install with builder enabled

```bash
export API_URL="https://app.daytona.io"
export API_KEY="dtn_..."

# Same bucket / credentials as services.snapshotManager.storage.s3.* in daytona-region
export AWS_REGION="us-east-1"
export AWS_DEFAULT_BUCKET="my-org-daytona-region-us"
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_ENDPOINT_URL="https://s3.us-east-1.amazonaws.com"

curl -sSL https://download.daytona.io/install.sh | sudo -E bash
```

`sudo -E` preserves the env vars so they reach the systemd unit. If the runner is an EC2 instance with an instance profile carrying S3 access, leave `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` blank — the AWS SDK picks up instance-metadata credentials.

### Verify

```bash
sudo grep -E '^Environment=AWS_' /etc/systemd/system/daytona-runner.service
```

All five `AWS_*` lines should be populated (or empty if you're relying on an instance profile). To change values after install, edit the unit file, then `sudo systemctl daemon-reload && sudo systemctl restart daytona-runner`.

### IAM policy

Minimum policy required against the bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ],
    "Resource": [
      "arn:aws:s3:::<your-bucket>",
      "arn:aws:s3:::<your-bucket>/*"
    ]
  }]
}
```

## Override with env vars
The following environment variables can be set to override default values in the install script:

| Variable Name            | Description                                                      | Default Value / Notes                       |
|------------------------- |------------------------------------------------------------------|---------------------------------------------|
| `CONTAINER_RUNTIME`      | Container runtime to use                                         | `sysbox-runc`                              |
| `API_TOKEN`              | API token for runner                                             | Auto-generated or user-provided            |
| `TLS_CERT_FILE`          | Path to TLS certificate file                                     | `/etc/letsencrypt/live/$DOMAIN/fullchain.pem` |
| `TLS_KEY_FILE`           | Path to TLS key file                                             | `/etc/letsencrypt/live/$DOMAIN/privkey.pem`   |
| `ENABLE_TLS`             | Enable TLS for runner                                            | `false`                                    |
| `API_PORT`               | Port for runner API                                              | `3000`                                     |
| `LOG_FILE_PATH`          | Path to runner log file                                          | `/var/log/daytona-runner.log`               |
| `LOG_LEVEL`              | Log level                                                        | `info`                                     |
| `AWS_ENDPOINT_URL`       | S3-compatible endpoint URL | `https://s3.us-east-1.amazonaws.com`        |
| `AWS_ACCESS_KEY_ID`      | IAM access key | (empty — disables declarative builder)     |
| `AWS_SECRET_ACCESS_KEY`  | IAM secret key | (empty — disables declarative builder)     |
| `AWS_REGION`             | AWS region | `us-east-1`                                |
| `AWS_DEFAULT_BUCKET`     | Name | `daytona`                                  |
| `SSH_GATEWAY_ENABLE`     | Enable SSH gateway                                               | `true` or `false` (auto-detected)          |
| `SSH_PUBLIC_KEY`         | SSH gateway public key                                           | Fetched from API                           |
| `SSH_HOST_KEY_PATH`      | Path to SSH host key                                             | `/etc/ssh/ssh_host_rsa_key`                |
| `SERVER_URL`             | Daytona API URL                                                  | User-provided                              |

You can set these variables before running the install script to customize the runner configuration.
