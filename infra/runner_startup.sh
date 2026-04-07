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
# Remove --ephemeral so the runner stays alive for multiple jobs
sudo -u runner ./config.sh --url "${REPO_URL}" --token "${RUNNER_TOKEN}" --unattended --labels gcp-spot-runner

# 4. Run in background and monitor
echo "--- Running ---"
# Run the runner in the background
sudo -u runner ./run.sh &
RUNNER_PID=$!

echo "--- Starting Idle Monitor ---"
# Idle monitor: If no job is running (no Runner.Worker process) for 10 minutes, shut down.
IDLE_COUNT=0
MAX_IDLE=10 # 10 minutes

while true; do
    sleep 60
    if pgrep -f "Runner.Worker" > /dev/null; then
        echo "Runner is busy. Resetting idle counter."
        IDLE_COUNT=0
    else
        IDLE_COUNT=$((IDLE_COUNT + 1))
        echo "Runner is idle. Idle count: ${IDLE_COUNT}/${MAX_IDLE}"
    fi

    if [ $IDLE_COUNT -ge $MAX_IDLE ]; then
        echo "--- Idle timeout reached. Shutting Down ---"
        break
    fi
    
    # Also check if the main runner process died
    if ! kill -0 $RUNNER_PID 2>/dev/null; then
        echo "--- Main runner process died. Shutting Down ---"
        break
    fi
done

echo "--- Shutting Down and Deleting Self ---"
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/name")
INSTANCE_ZONE=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" | awk -F/ '{print $NF}')

gcloud compute instances delete "$INSTANCE_NAME" --zone="$INSTANCE_ZONE" --project="$PROJECT_ID" --quiet
