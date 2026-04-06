# Global GitHub Actions Runner Provisioner

This project provides a scalable, ephemeral GitHub Actions runner infrastructure on Google Cloud Platform (GCP). It automatically provisions Compute Engine VMs in response to GitHub `workflow_job` webhooks and ensures they are cleaned up immediately after use.

## Architecture

1.  **GitHub Webhook**: GitHub is configured to send `workflow_job` events to the Cloud Function URL.
2.  **Cloud Function (`cloud_function/`)**:
    *   **On `queued`**: Fetches a registration token from GitHub, selects a random zone, and creates a GCE VM using a pre-built instance template.
    *   **On `completed`**: Identifies the VM associated with the job and deletes it.
3.  **Compute Engine VM (`infra/runner_startup.sh`)**:
    *   Runs a startup script that fetches metadata, configures the ephemeral runner, and executes the job.
    *   **Standard Instances**: Uses `STANDARD` instances (not Spot) for maximum reliability and to avoid preemption during critical jobs.
    *   **Self-Deletion**: After the job completes, the VM attempts to delete itself via the Google Cloud CLI as a fallback to the Cloud Function's deletion logic.
4.  **Artifact Registry**: Includes a Docker Hub pull-through cache to speed up image pulls and avoid rate limits.

## Project Structure

*   `cloud_function/`: Python source code for the GitHub trigger.
*   `infra/`: Terraform configuration for all GCP resources (SA, IAM, Instance Templates, etc.).
*   `scripts/`: Utility scripts for building the base VM image.

## Setup & Configuration

### Prerequisites
*   GCP Project with billing enabled.
*   GitHub Personal Access Token (PAT) with `repo` scope (stored in Secret Manager as `github-pat`).
*   GitHub Webhook Secret (stored in Secret Manager as `github-webhook-secret`).

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

The system is designed to be "zero-maintenance" regarding dead VMs. Cleanup happens via two redundant paths:
1.  **Webhook Path**: Cloud Function deletes the VM when GitHub sends a `completed` action.
2.  **Self-Delete Path**: The VM runs `gcloud compute instances delete` as its final command.

Both service accounts (`gcf-github-trigger-sa` and `github-runner-sa`) have `roles/compute.instanceAdmin.v1` permissions in the hub project to facilitate this.

## Security
*   **No Persistent Access**: Runners are ephemeral and use short-lived tokens.
*   **Secret Management**: All sensitive credentials are retrieved from GCP Secret Manager at runtime.
*   **IAM Least Privilege**: Service accounts are scoped specifically to the tasks they perform.
