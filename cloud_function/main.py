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
# Default zone if region logic fails
DEFAULT_ZONE = os.environ.get("GCP_ZONE", f"{GCP_REGION}-a")

# The IDs of the secrets in Secret Manager
PAT_SECRET_ID = os.environ.get("PAT_SECRET_ID", "github-pat")
WEBHOOK_SECRET_ID = os.environ.get("WEBHOOK_SECRET_ID", "github-webhook-secret")
TEMPLATE_PREFIX = os.environ.get("TEMPLATE_PREFIX", "github-spot-runner-")

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

def _get_latest_template(project_id: str, prefix: str) -> compute_v1.InstanceTemplate:
    """Finds the most recent instance template with a given prefix."""
    try:
        client = compute_v1.InstanceTemplatesClient()
        templates = client.list(project=project_id)
        
        filtered_templates = [t for t in templates if t.name.startswith(prefix)]

        if not filtered_templates:
            raise RuntimeError(f"No instance templates found with prefix '{prefix}' in project '{project_id}'.")

        latest_template = sorted(
            filtered_templates,
            key=lambda t: t.creation_timestamp,
            reverse=True
        )[0]
        
        print(f"INFO: Found latest template: {latest_template.name}")
        return latest_template
    except Exception as e:
        print(f"ERROR: Error finding latest instance template with prefix '{prefix}': {e}")
        raise

def _get_random_zone(region: str) -> str:
    """Returns a random zone for the given region."""
    # Common zones for us-central1 and us-west1
    zones = {
        "us-central1": ["us-central1-a", "us-central1-b", "us-central1-c", "us-central1-f"],
        "us-west1": ["us-west1-a", "us-west1-b", "us-west1-c"]
    }
    region_zones = zones.get(region, [f"{region}-a"])
    return random.choice(region_zones)


def github_webhook_handler(request):
    """
    Cloud Function to provision a GitHub Actions runner VM based on a webhook.
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
        print(f"INFO: Ignoring webhook, not a workflow job.")
        return ("Ignoring request", 200)

    action = payload.get("action")
    repo_full_name = payload["repository"]["full_name"]
    repo_url = payload["repository"]["html_url"]
    job_id = payload["workflow_job"]["id"]
    
    # Identify which instance to delete
    # 1. Check if GitHub told us which runner ran the job
    runner_name_from_payload = payload["workflow_job"].get("runner_name")
    if runner_name_from_payload and runner_name_from_payload.startswith("gh-runner-"):
        instance_name = runner_name_from_payload.lower()
    else:
        # Fallback to the name we would have given it
        instance_name = f"gh-runner-{repo_full_name.replace('/', '-')}-{job_id}".lower()

    if action == "completed":
        print(f"INFO: Job '{job_id}' completed. Skipping aggressive deletion; VM will self-delete when idle.")
        return ("Skipping deletion, VM handles itself", 200)

    if action != "queued":
        print(f"INFO: Ignoring action '{action}'.")
        return ("Ignoring request", 200)
    
    # 2.5 Filter by label
    labels = payload["workflow_job"].get("labels", [])
    if "gcp-spot-runner" not in labels:
        print(f"INFO: Ignoring queued job '{job_id}', does not request 'gcp-spot-runner' label (labels: {labels}).")
        return ("Ignoring request", 200)
    
    print(f"INFO: Received queued job '{job_id}' for repo '{repo_full_name}'.")

    try:
        # 3. Get a short-lived registration token from GitHub
        github_pat = _get_secret(GCP_PROJECT, PAT_SECRET_ID)
        
        headers = {
            "Authorization": f"token {github_pat}",
            "Accept": "application/vnd.github.v3+json",
        }

        # 3.5 Check for existing capacity before provisioning
        try:
            # 1. Get GCE instance count
            instance_client = compute_v1.InstancesClient()
            # We check all zones to be sure
            zones = ["us-central1-a", "us-central1-b", "us-central1-c", "us-central1-f"]
            total_gce_instances = 0
            for zone in zones:
                instance_list = instance_client.list(project=GCP_PROJECT, zone=zone)
                # Count instances matching our prefix
                total_gce_instances += sum(1 for i in instance_list if i.name.startswith("gh-runner-"))
            
            # 2. Get GitHub busy count
            runners_url = f"https://api.github.com/repos/{repo_full_name}/actions/runners"
            runners_resp = requests.get(runners_url, headers=headers)
            busy_runners = 0
            if runners_resp.status_code == 200:
                runners = runners_resp.json().get("runners", [])
                # Only count online runners that have our label
                matching_online = [r for r in runners if r.get("status") == "online" and any(l.get("name") == "gcp-spot-runner" for l in r.get("labels", []))]
                busy_runners = sum(1 for r in matching_online if r.get("busy") == True)
            
            print(f"INFO: Capacity Check - GCE Instances: {total_gce_instances}, Busy Runners in GitHub: {busy_runners}")
            
            if total_gce_instances > busy_runners:
                print(f"INFO: Existing capacity detected ({total_gce_instances - busy_runners} available/booting). Skipping VM provisioning for job {job_id}.")
                return ("Capacity available", 200)
                
        except Exception as e:
            print(f"WARNING: Failed capacity check: {e}. Proceeding with default provisioning logic.")

        api_url = f"https://api.github.com/repos/{repo_full_name}/actions/runners/registration-token"
        
        resp = requests.post(api_url, headers=headers)
        if resp.status_code != 201:
            print(f"ERROR: GitHub API error: {resp.text}")
            resp.raise_for_status()
        
        runner_token = resp.json().get("token")
        if not runner_token:
            raise RuntimeError("GitHub API response did not include a runner token.")
        
        print("INFO: Successfully obtained runner registration token from GitHub.")

        # 4. Find the latest instance template
        template = _get_latest_template(GCP_PROJECT, TEMPLATE_PREFIX)

        # 5. Spin up the VM with Retries
        instance_client = compute_v1.InstancesClient()

        # Merge metadata from the template with our new items
        new_metadata_items = []
        if template.properties.metadata and template.properties.metadata.items:
            new_metadata_items = list(template.properties.metadata.items)
        
        new_metadata_items.append(compute_v1.Items(key="github_token", value=runner_token))
        new_metadata_items.append(compute_v1.Items(key="github_repo", value=repo_url))

        instance_resource = compute_v1.Instance()
        instance_resource.name = f"gh-runner-{repo_full_name.replace('/', '-')}-{job_id}".lower()
        instance_resource.metadata = compute_v1.Metadata(items=new_metadata_items)
        
        # Override template to use STANDARD instead of SPOT for higher reliability
        instance_resource.scheduling = compute_v1.Scheduling(
            provisioning_model="STANDARD",
            preemptible=False
        )

        # 5. Spin up the VM - Iterate through zones on failure
        instance_client = compute_v1.InstancesClient()
        zones = ["us-central1-a", "us-central1-b", "us-central1-c", "us-central1-f"]
        random.shuffle(zones) # Start with a random zone to spread load
        
        last_error = None
        for selected_zone in zones:
            print(f"INFO: Attempting to provision instance '{instance_resource.name}' in zone '{selected_zone}'...")
            
            try:
                request_insert = compute_v1.InsertInstanceRequest(
                    project=GCP_PROJECT,
                    zone=selected_zone,
                    source_instance_template=template.self_link,
                    instance_resource=instance_resource,
                )
                
                operation = instance_client.insert(request=request_insert)
                
                # Wait up to 60s to catch immediate or near-immediate failures (like resource exhaustion)
                try:
                    operation.result(timeout=60)
                    print(f"INFO: Successfully provisioned in {selected_zone}. Operation: {operation.name}")
                    return ("Successfully provisioned VM", 200)
                except Exception as e:
                    # If it's a timeout, it means it's likely proceeding fine (just not finished yet)
                    if "DeadlineExceeded" in str(e) or "Timeout" in str(e) or "timeout" in str(e).lower():
                        print(f"INFO: Provisioning request still pending in {selected_zone} after 60s, proceeding asynchronously. Operation: {operation.name}")
                        return ("Successfully requested provisioning", 200)
                    # Otherwise, it's a real error (like Resource Exhausted)
                    print(f"WARNING: Provisioning failed in {selected_zone}: {e}")
                    last_error = e
                    continue
                
            except Exception as e:
                print(f"WARNING: Request failed in {selected_zone}: {e}")
                last_error = e
                continue

        raise last_error if last_error else RuntimeError("Failed to provision in any zone.")

    except Exception as e:
        print(f"ERROR: Failed to provision runner for job {job_id}: {e}")
        return ("Error processing request", 500)
