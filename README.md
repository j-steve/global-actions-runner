# Global GitHub Actions Runner Provisioner

This project provides a scalable, ephemeral GitHub Actions runner infrastructure on Google Cloud Platform (GCP). It automatically provisions Compute Engine VMs in response to GitHub `workflow_job` webhooks and ensures they are cleaned up immediately after use or idleness.

## Architecture

1.  **GitHub Webhook**: GitHub is configured to send `workflow_job` events to the Cloud Function URL.
2.  **Cloud Function (`cloud_function/`)**:
    *   **On `queued`**: 
        *   **Label Filtering**: Only processes jobs that specifically request the `gcp-spot-runner` label.
        **Global Capacity-Aware Provisioning**: Prevents redundant VM spawns. It checks for existing GCE instances explicitly labeled as `idle`.
        *   **Idle Detection**: Only instances explicitly labeled as `idle` are considered available capacity. 
        *   **Booting/Busy as Busy**: If an instance is `booting` or `busy`, it is excluded from the capacity count. This ensures that new jobs don't wait for a slow-booting VM or a VM that might be a "zombie." If `Idle Instances == 0`, the function will proceed to provision a new VM.
        *   **Relentless Global Hunter**: If no capacity exists, the function enters a **9-minute loop** (hunting round). It prioritizes `us-central1`, shuffling its zones first, and then sequentially falls back to other regions (`us-west1`, `us-east1`, `us-east4`) until capacity is found. It retries every 30 seconds if all regions are full (`ZONE_RESOURCE_POOL_EXHAUSTED`). This global search ensures builds never fail due to regional shortages.
        *   **Standard Provisioning Override**: The function explicitly overrides the instance template to use the `STANDARD` provisioning model (non-preemptible) to ensure availability during global Spot shortages.
        *   **On `completed`**: Does **not** aggressively delete the VM. It allows the VM to stay up and potentially pick up more jobs from the queue.
        3.  **Compute Engine VM (`infra/runner_startup.sh`)**:
        *   **Persistent Runner**: The runner is configured to stay registered after completing a job, allowing it to handle sequential tasks without rebooting.
        *   **Idle Monitor**: Runs a background loop that monitors for the `Runner.Worker` process and updates its `runner-state` label (`booting`, `busy`, or `idle`). If the runner remains idle (no job running) for **10 consecutive minutes**, the VM automatically deletes itself.
        *   **Hard Lifetime Cap**: VMs are configured with a `max_run_duration` of **120 minutes** as a safety "dead man's switch."
        *   **Standard Instances**: Uses `STANDARD` instances for maximum reliability.
        4.  **Artifact Registry**: Includes a Docker Hub pull-through cache to speed up image pulls.

        ## State-Aware Scaling
        To solve the issue where new jobs were stuck waiting for VMs that were already busy but not yet reported as such by GitHub, we've implemented direct state-tracking via GCE labels:
        1.  **Booting**: Every new VM starts as `booting`. The provisioner treats this as "busy."
        2.  **Busy**: When a VM picks up a job (detected via the `Runner.Worker` process), it labels itself as `busy`.
        3.  **Idle**: If a VM is not running a job for 60 seconds, it labels itself as `idle`.

        The Cloud Function **only skips provisioning** if it finds an instance explicitly labeled as `idle`. This ensures 100% parallel scaling when needed while still allowing warm instances to be reused when truly idle.


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
2.  **Self-Deletion**: 
    *   **Standard Cleanup**: If the runner remains idle (no job running) for **10 consecutive minutes**, the VM automatically deletes itself.
    *   **Sticky Central Hub**: If a runner is located in `us-central1` and it is the **youngest** live runner in that region (by creation time), it will extend its idle timeout to **60 minutes** before self-deleting. This ensures we keep exactly one "warm" runner in our primary region longer than usual, avoiding race conditions where multiple runners might otherwise simultaneously shut down.

3.  **Hard Cap**: GCP will automatically delete the instance after 120 minutes regardless of state.

This approach ensures that VMs stay alive to process back-to-back jobs (saving provisioning time) but eventually clean themselves up to save costs when the queue is empty. Both service accounts have the necessary permissions to facilitate this.

## Security
*   **Ephemeral Lifecycle**: Although runners stay registered for multiple jobs, the underlying VM is short-lived and automatically destroyed.
*   **Secret Management**: All sensitive credentials (PAT, Webhook Secret) are retrieved from GCP Secret Manager at runtime.
*   **IAM Least Privilege**: Service accounts are scoped specifically to the tasks they perform.
