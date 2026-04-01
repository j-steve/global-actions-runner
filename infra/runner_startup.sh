#!/bin/bash
set -ex

# 1. Fetch metadata
RUNNER_TOKEN=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/github_token")
REPO_URL=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/github_repo")
PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id")

echo "--- GITHUB RUNNER STARTING ---"

# 2. Pre-fetch PAT for the shutdown script (to avoid gcloud overhead during preemption)
# The runner service account needs secretmanager.secretAccessor role.
gcloud secrets versions access latest --secret="github-pat" --project="$PROJECT_ID" > /home/runner/.github-pat
chmod 600 /home/runner/.github-pat
chown runner:runner /home/runner/.github-pat

cd /home/runner/actions-runner

# 3. Configure
echo "--- Configuring ---"
sudo -u runner ./config.sh --url "${REPO_URL}" --token "${RUNNER_TOKEN}" --ephemeral --unattended --labels gcp-spot-runner

# 4. Run
echo "--- Running ---"
sudo -u runner ./run.sh

# 5. Normal Finish
echo "--- Shutting Down ---"
shutdown -h now
