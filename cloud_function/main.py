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

def _get_github_runner_states(repo_full_name, pat):
    """
    Fetches the current status of all runners for the repository from GitHub.
    This allows us to verify if a 'RUNNING' VM is actually connected.
    """
    try:
        url = f"https://api.github.com/repos/{repo_full_name}/actions/runners"
        headers = {
            "Authorization": f"token {pat}",
            "Accept": "application/vnd.github.v3+json",
        }
        resp = requests.get(url, headers=headers, timeout=10)
        resp.raise_for_status()
        # Map runner name -> status (online/offline)
        return {r["name"]: r["status"] for r in resp.json().get("runners", [])}
    except Exception as e:
        print(f"WARNING: Failed to fetch runner states from GitHub: {e}")
        return {}

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
        github_pat = _get_secret(GCP_PROJECT, PAT_SECRET_ID) # Fetch PAT early for audit
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

    # --- ZOMBIE AUDIT ---
    # Before checking capacity, we ask GitHub what it sees.
    gh_runner_states = _get_github_runner_states(repo_full_name, github_pat)

    try:
        instance_client = compute_v1.InstancesClient()
        
        # 3. Find an available static runner
        target_instance = None
        target_zone = None
        
        print("INFO: Checking status of all static runners...")
        shuffled_runners = list(STATIC_RUNNERS)
        random.shuffle(shuffled_runners)
        for runner in shuffled_runners:
            try:
                instance = instance_client.get(project=GCP_PROJECT, zone=runner["zone"], instance=runner["name"])
                label_state = instance.labels.get("runner-state", "unknown")
                
                # Skip if the VM is already booting or busy and currently running (or staging)
                if instance.status in ["RUNNING", "PROVISIONING", "STAGING"] and label_state in ["booting", "busy"]:
                    # Wait, check if it's a zombie first
                    gh_status = gh_runner_states.get(runner["name"], "not_registered")
                    if instance.status == "RUNNING" and gh_status != "online":
                        # If it is RUNNING but offline in GitHub, it's a zombie, we shouldn't skip it, we should kill it!
                        pass
                    else:
                        print(f"INFO: Runner '{runner['name']}' is actively {instance.status} with label '{label_state}'. Skipping to avoid collision.")
                        continue

                # --- ZOMBIE DETECTION ---
                # If GCP says the VM is RUNNING, but GitHub says it is NOT online, it's a zombie.
                # We force-stop it so it can be kickstarted cleanly.
                gh_status = gh_runner_states.get(runner["name"], "not_registered")
                if instance.status == "RUNNING" and gh_status != "online":
                    print(f"ZOMBIE DETECTED: Runner '{runner['name']}' is RUNNING in GCP but '{gh_status}' in GitHub. Stopping instance.")
                    instance_client.stop(project=GCP_PROJECT, zone=runner["zone"], instance=runner["name"]).result()
                    # Update local status variable so the logic below sees it as available
                    instance = instance_client.get(project=GCP_PROJECT, zone=runner["zone"], instance=runner["name"])
                    label_state = instance.labels.get("runner-state", "unknown")

                print(f"INFO: Runner '{runner['name']}' is {instance.status} with label '{label_state}'.")
                
                # If running and idle, we're good
                if instance.status == "RUNNING" and label_state == "idle":
                    print(f"INFO: Static runner '{runner['name']}' is ALREADY RUNNING and IDLE. It should pick up the job.")
                    return ("Capacity available", 200)
                
                # --- AGGRESSIVE SELF-HEALING ---
                # We want to rescue runners in almost any state if they aren't active.
                # If it's TERMINATED, it's ready for a fresh start.
                # If it's STOPPING, we wait a few seconds for it to finish, then start it.
                if instance.status in ["TERMINATED", "STOPPING", "PROVISIONING", "STAGING"]:
                    print(f"INFO: Found runner '{runner['name']}' in state '{instance.status}'. Rescue/Restart initiated.")
                    
                    # If it's stopping, give it a moment to reach TERMINATED
                    if instance.status == "STOPPING":
                        print(f"INFO: Runner {runner['name']} is stopping. Waiting for it to finish...")
                        for _ in range(5): # Wait up to 10 seconds
                            time.sleep(2)
                            instance = instance_client.get(project=GCP_PROJECT, zone=runner["zone"], instance=runner["name"])
                            if instance.status == "TERMINATED":
                                break
                    
                    target_instance = runner["name"]
                    target_zone = runner["zone"]
                    break
            except Exception as e:
                print(f"WARNING: Could not check status of {runner['name']}: {e}")

        if not target_instance:
            print("INFO: No static runners available (all are currently BUSY). GitHub will retry.")
            return ("No capacity available", 200)

        # 4. Get a short-lived registration token from GitHub
        api_url = f"https://api.github.com/repos/{repo_full_name}/actions/runners/registration-token"
        headers = {
            "Authorization": f"token {github_pat}",
            "Accept": "application/vnd.github.v3+json",
        }
        
        resp = requests.post(api_url, headers=headers)
        resp.raise_for_status()
        runner_token = resp.json().get("token")

        # 5. Update Metadata/Labels and START Instance
        print(f"INFO: Preparing {target_instance} for startup...")
        
        # A. Force-reset the runner-state label to 'booting' to fix zombie states
        try:
            labels_op = instance_client.set_labels(
                project=GCP_PROJECT,
                zone=target_zone,
                instance=target_instance,
                instances_set_labels_request_resource=compute_v1.InstancesSetLabelsRequest(
                    label_fingerprint=instance_client.get(project=GCP_PROJECT, zone=target_zone, instance=target_instance).label_fingerprint,
                    labels={"runner-state": "booting", "goog-terraform-provisioned": "true"}
                )
            )
            print(f"INFO: Reset label for {target_instance} to 'booting'.")
        except Exception as e:
            print(f"WARNING: Failed to reset label for {target_instance}: {e}")

        # B. Update Metadata with NEW Token
        instance_data = instance_client.get(project=GCP_PROJECT, zone=target_zone, instance=target_instance)
        metadata = instance_data.metadata
        items = list(metadata.items)
        # ... (update token logic)
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
        instance_client.set_metadata(project=GCP_PROJECT, zone=target_zone, instance=target_instance, metadata_resource=metadata).result()
        
        # C. Start Instance
        print(f"INFO: Sending START command to {target_instance}...")
        instance_client.start(project=GCP_PROJECT, zone=target_zone, instance=target_instance).result()
        
        print(f"INFO: Successfully kickstarted {target_instance}.")
        return ("Successfully started static runner", 200)

    except Exception as e:
        print(f"ERROR: Failed to manage static runner: {e}")
        return ("Error processing request", 500)
