# Global GitHub Actions Runner Provisioner

This project provides a scalable, ephemeral GitHub Actions runner infrastructure on Google Cloud Platform (GCP). It automatically provisions Compute Engine VMs in response to GitHub `workflow_job` webhooks and ensures they are cleaned up immediately after use.

## Architecture

1.  **GitHub Webhook**: GitHub is configured to send `workflow_job` events to the Cloud Function URL.
2.  **Cloud Function (`cloud_function/`)**:
    *   **On `queued`**: 
        *   **Label Filtering**: Only processes jobs that specifically request the `gcp-spot-runner` label.
        *   **Capacity-Aware Provisioning**: Prevents redundant VM spawns. It checks the number of existing GCE instances against the number of *busy* runners in GitHub. If `Total Instances > Busy Runners`, it assumes a VM is either idle or currently booting and will pick up the queued job, so it skips starting a new one.
    *   **On `completed`**: Does **not** aggressively delete the VM. It allows the VM to stay up and potentially pick up more jobs from the queue.
3.  **Compute Engine VM (`infra/runner_startup.sh`)**:
    *   **Persistent Runner**: The runner is configured without the `--ephemeral` flag, so it stays registered after completing a job.
    *   **Idle Monitor**: Runs a background loop that monitors for the `Runner.Worker` process. If the runner remains idle (no job running) for **10 consecutive minutes**, the VM automatically deletes itself.
    *   **Standard Instances**: Uses `STANDARD` instances for maximum reliability.
4.  **Artifact Registry**: Includes a Docker Hub pull-through cache to speed up image pulls.

## Project Structure

*   `cloud_function/`: Python source code for the GitHub trigger.
*   `infra/`: Terraform configuration for all GCP resources (SA, IAM, Instance Templates, etc.).
*   `scripts/`: Utility scripts for building the base VM image.

## Setup & Configuration

### Prerequisites
*   GCP Project with billing enabled.
*   GitHub Personal Access Token (PAT) with `repo` scope (stored in Secret Manager as `github-pat`).
*   GitHub Webhook Secret (stored in Secret Manager as `github-webhook-secret`).

### Usage
To use these runners in your GitHub Action workflows, specify the following label in your `runs-on` field:

```yaml
jobs:
  my-job:
    runs-on: [self-hosted, gcp-spot-runner]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on GCP!"
```

### Infrastructure Deployment
1.  Navigate to the `infra/` directory.
2.  Initialize Terraform: `terraform init`.
3.  Apply the configuration: `terraform apply`.
4.  The output will provide the `cloud_function_trigger_url`. Set this as the Payload URL in your GitHub repository/organization webhooks with the content type `application/json`.

### Base Image
The runners use a custom base image (`github-runner-base-v4`) pre-loaded with Docker and common dependencies. To update the image:
1.  Run `scripts/build_base_image.sh`.
2.  Update the `source_image` in `infra/main.tf` to the new image name.

## Maintenance & Cleanup

The system is designed to be "zero-maintenance" regarding dead VMs. Cleanup is handled by the **Idle Monitor** running on the VM:
1.  **Idle Detection**: The VM checks every minute if a job is running.
2.  **Self-Deletion**: If it remains idle for 10 minutes, it runs `gcloud compute instances delete` to terminate itself.

This approach ensures that VMs stay alive to process back-to-back jobs (saving provisioning time) but eventually clean themselves up to save costs when the queue is empty. Both service accounts have the necessary permissions to facilitate this.

## Security
*   **No Persistent Access**: Runners are ephemeral and use short-lived tokens.
*   **Secret Management**: All sensitive credentials are retrieved from GCP Secret Manager at runtime.
*   **IAM Least Privilege**: Service accounts are scoped specifically to the tasks they perform.
