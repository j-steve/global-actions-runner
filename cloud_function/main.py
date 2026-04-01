import os
import logging
import requests
import hmac
import hashlib
import json
import time

from google.cloud import compute_v1
from google.cloud import secretmanager

# --- Configuration ---
GCP_PROJECT = os.environ.get("GCP_PROJECT", "global-actions-runner")
GCP_ZONE = os.environ.get("GCP_ZONE", "us-central1-a")

PAT_SECRET_ID = "github-pat"
WEBHOOK_SECRET_ID = "github-webhook-secret" # Secret containing the webhook secret
TEMPLATE_PREFIX = "github-spot-runner-"

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
            # Note: During initial setup, ensure GitHub and GCP secrets match.
            return ("Forbidden", 403)
    except Exception as e:
        print(f"ERROR: Error during signature verification: {e}")
        return ("Internal Server Error", 500)

    print("INFO: Webhook signature verified successfully.")
    
    payload = request.get_json()

    # 2. Validate the webhook is a 'workflow_job' with a 'queued' status
    if not payload or payload.get("action") != "queued" or "workflow_job" not in payload:
        print(f"INFO: Ignoring webhook, not a 'queued' workflow job. Action was: {payload.get('action') if payload else 'None'}")
        return ("Ignoring request", 200)

    repo_full_name = payload["repository"]["full_name"]
    repo_url = payload["repository"]["html_url"]
    job_id = payload["workflow_job"]["id"]
    
    print(f"INFO: Received job '{job_id}' for repo '{repo_full_name}'.")

    try:
        # 3. Get a short-lived registration token from GitHub
        github_pat = _get_secret(GCP_PROJECT, PAT_SECRET_ID)
        
        headers = {
            "Authorization": f"token {github_pat}",
            "Accept": "application/vnd.github.v3+json",
        }
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

        # 5. Spin up the Spot VM
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

        request_insert = compute_v1.InsertInstanceRequest(
            project=GCP_PROJECT,
            zone=GCP_ZONE,
            source_instance_template=template.self_link,
            instance_resource=instance_resource,
        )
        
        print(f"INFO: Requesting provisioning of instance '{instance_resource.name}' using template '{template.name}'...")
        instance_client.insert(request=request_insert)
        print(f"INFO: Successfully requested provisioning of instance '{instance_resource.name}'.")

    except Exception as e:
        print(f"ERROR: Failed to provision runner for job {job_id}: {e}")
        return ("Error processing request", 500)

    return ("Successfully provisioned VM", 200)
