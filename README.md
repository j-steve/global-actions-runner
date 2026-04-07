# Global GitHub Actions Runner Provisioner

This project provides a scalable, ephemeral GitHub Actions runner infrastructure on Google Cloud Platform (GCP). It automatically provisions Compute Engine VMs in response to GitHub `workflow_job` webhooks and ensures they are cleaned up immediately after use or idleness.

## Architecture

1.  **GitHub Webhook**: GitHub is configured to send `workflow_job` events to the Cloud Function URL.
2.  **Cloud Function (`cloud_function/`)**:
    *   **On `queued`**: 
        *   **Label Filtering**: Only processes jobs that specifically request the `gcp-spot-runner` label.
        *   **Capacity-Aware Provisioning**: Prevents redundant VM spawns. It checks the number of existing GCE instances against the number of *busy* runners in GitHub. If `Total Instances > Busy Runners`, it assumes a VM is either idle or currently booting and will pick up the queued job, so it skips starting a new one.
        *   **Multi-Zone Resilience**: If a GCP zone is out of resources (e.g., `ZONE_RESOURCE_POOL_EXHAUSTED`), the function shuffles and iterates through all available zones (`us-central1-a`, `b`, `c`, `f`) until provisioning succeeds.
        *   **High Timeout**: The function has a 300-second timeout and waits up to 60 seconds per zone to catch and handle resource exhaustion errors.
    *   **On `completed`**: Does **not** aggressively delete the VM. It allows the VM to stay up and potentially pick up more jobs from the queue.
3.  **Compute Engine VM (`infra/runner_startup.sh`)**:
    *   **Persistent Runner**: The runner is configured to stay registered after completing a job, allowing it to handle sequential tasks without rebooting.
    *   **Idle Monitor**: Runs a background loop that monitors for the `Runner.Worker` process. If the runner remains idle (no job running) for **10 consecutive minutes**, the VM automatically deletes itself.
    *   **Hard Lifetime Cap**: VMs are configured with a `max_run_duration` of **120 minutes** as a safety "dead man's switch."
    *   **Standard Instances**: Uses `STANDARD` instances for maximum reliability.
4.  **Artifact Registry**: Includes a Docker Hub pull-through cache to speed up image pulls.

## Project Structure

*   `cloud_function/`: Python source code for the GitHub trigger.
*   `infra/`: Terraform configuration for all GCP resources (SA, IAM, Instance Templates, etc.).
*   `scripts/`: Utility scripts for building the base VM image and setting up the Gemini CLI.

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
3.  **Hard Cap**: GCP will automatically delete the instance after 120 minutes regardless of state.

This approach ensures that VMs stay alive to process back-to-back jobs (saving provisioning time) but eventually clean themselves up to save costs when the queue is empty. Both service accounts have the necessary permissions to facilitate this.

## Security
*   **Ephemeral Lifecycle**: Although runners stay registered for multiple jobs, the underlying VM is short-lived and automatically destroyed.
*   **Secret Management**: All sensitive credentials (PAT, Webhook Secret) are retrieved from GCP Secret Manager at runtime.
*   **IAM Least Privilege**: Service accounts are scoped specifically to the tasks they perform.
