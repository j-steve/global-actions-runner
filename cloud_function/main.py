import os
import logging
import requests
import hmac
import hashlib
import json
import time
import random

from google.cloud import compute_v1
from google.cloud import secretmanager

# --- Configuration (Passed from Terraform Environment Variables) ---
GCP_PROJECT = os.environ.get("GCP_PROJECT", "global-actions-runner")
GCP_REGION = os.environ.get("GCP_REGION", "us-central1")

# The IDs of the secrets in Secret Manager
PAT_SECRET_ID = os.environ.get("PAT_SECRET_ID", "github-pat")
WEBHOOK_SECRET_ID = os.environ.get("WEBHOOK_SECRET_ID", "github-webhook-secret")

STATIC_RUNNERS = [
    {"name": "gh-static-runner-1", "zone": "us-central1-a"},
    {"name": "gh-static-runner-2", "zone": "us-central1-b"},
]

logging.basicConfig(level=logging.INFO)


def _get_secret(project_id: str, secret_id: str) -> str:
    """Fetches a secret from Google Cloud Secret Manager."""
    try:
        client = secretmanager.SecretManagerServiceClient()
        secret_name = f"projects/{project_id}/secrets/{secret_id}/versions/latest"
        response = client.access_secret_version(name=secret_name)
        return response.payload.data.decode("UTF-8")
    except Exception as e:
        print(f"ERROR: Error fetching secret '{secret_id}': {e}")
        raise

def github_webhook_handler(request):
    """
    Cloud Function to manage persistent GitHub Actions runner VMs.
    """
    # 1. Verify the webhook signature
    signature_header = request.headers.get("X-Hub-Signature-256")
    if not signature_header:
        print("ERROR: Missing X-Hub-Signature-256 header.")
        return ("Forbidden", 403)

    try:
        webhook_secret = _get_secret(GCP_PROJECT, WEBHOOK_SECRET_ID)
        request_body = request.get_data()
        
        expected_signature = "sha256=" + hmac.new(
            webhook_secret.encode(),
            request_body,
            hashlib.sha256
        ).hexdigest()

        if not hmac.compare_digest(expected_signature, signature_header):
            print("ERROR: Request signature does not match expected signature.")
            return ("Forbidden", 403)
    except Exception as e:
        print(f"ERROR: Error during signature verification: {e}")
        return ("Internal Server Error", 500)

    print("INFO: Webhook signature verified successfully.")
    
    payload = request.get_json()

    # 2. Validate the webhook is a 'workflow_job'
    if not payload or "workflow_job" not in payload:
        return ("Ignoring request", 200)

    action = payload.get("action")
    repo_full_name = payload["repository"]["full_name"]
    repo_url = payload["repository"]["html_url"]
    job_id = payload["workflow_job"]["id"]

    if action == "completed":
        print(f"INFO: Job '{job_id}' completed.")
        return ("Job completed", 200)

    if action != "queued":
        return ("Ignoring request", 200)
    
    # Check for label
    labels = payload["workflow_job"].get("labels", [])
    if "gcp-spot-runner" not in labels:
        print(f"INFO: Ignoring job '{job_id}', no 'gcp-spot-runner' label.")
        return ("Ignoring request", 200)
    
    print(f"INFO: Received queued job '{job_id}' for repo '{repo_full_name}'. Checking static capacity...")

    try:
        instance_client = compute_v1.InstancesClient()
        
        # 3. Find an available static runner
        target_instance = None
        target_zone = None
        
        for runner in STATIC_RUNNERS:
            try:
                instance = instance_client.get(project=GCP_PROJECT, zone=runner["zone"], instance=runner["name"])
                state = instance.labels.get("runner-state", "idle")
                
                # If running and idle, we're good
                if instance.status == "RUNNING" and state == "idle":
                    print(f"INFO: Static runner '{runner['name']}' is ALREADY RUNNING and IDLE. It should pick up the job.")
                    return ("Capacity available", 200)
                
                # If terminated, this is our candidate to start
                if instance.status == "TERMINATED":
                    print(f"INFO: Found terminated static runner: {runner['name']}. Selecting for startup.")
                    target_instance = runner["name"]
                    target_zone = runner["zone"]
                    break
            except Exception as e:
                print(f"WARNING: Could not check status of {runner['name']}: {e}")

        if not target_instance:
            print("INFO: No static runners available (all busy). GitHub will retry or job will wait.")
            return ("No capacity available", 200)

        # 4. Get a short-lived registration token from GitHub
        github_pat = _get_secret(GCP_PROJECT, PAT_SECRET_ID)
        api_url = f"https://api.github.com/repos/{repo_full_name}/actions/runners/registration-token"
        headers = {
            "Authorization": f"token {github_pat}",
            "Accept": "application/vnd.github.v3+json",
        }
        
        resp = requests.post(api_url, headers=headers)
        resp.raise_for_status()
        runner_token = resp.json().get("token")

        # 5. Update Metadata with NEW Token and START Instance
        print(f"INFO: Updating metadata and starting {target_instance}...")
        
        # Get existing metadata to preserve startup-script
        instance_data = instance_client.get(project=GCP_PROJECT, zone=target_zone, instance=target_instance)
        metadata = instance_data.metadata
        
        # Add/Update the token and repo
        items = list(metadata.items)
        found_token = False
        found_repo = False
        for item in items:
            if item.key == "github_token":
                item.value = runner_token
                found_token = True
            if item.key == "github_repo":
                item.value = repo_url
                found_repo = True
        
        if not found_token:
            items.append(compute_v1.Items(key="github_token", value=runner_token))
        if not found_repo:
            items.append(compute_v1.Items(key="github_repo", value=repo_url))
            
        metadata.items = items
        
        # Set Metadata
        instance_client.set_metadata(project=GCP_PROJECT, zone=target_zone, instance=target_instance, metadata_resource=metadata).result()
        
        # Start Instance
        instance_client.start(project=GCP_PROJECT, zone=target_zone, instance=target_instance).result()
        
        print(f"INFO: Successfully started {target_instance}.")
        return ("Successfully started static runner", 200)

    except Exception as e:
        print(f"ERROR: Failed to manage static runner: {e}")
        return ("Error processing request", 500)
