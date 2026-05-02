#!/bin/bash
set -ex

PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id")
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/name")
INSTANCE_ZONE=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" | awk -F/ '{print $NF}')

# 0. Set initial state immediately to avoid zombie labels
gcloud compute instances add-labels "$INSTANCE_NAME" --zone="$INSTANCE_ZONE" --labels="runner-state=booting" --project="$PROJECT_ID" --quiet || true

# 1. Fetch metadata
RUNNER_TOKEN=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/github_token")
REPO_URL=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/github_repo")

echo "--- GITHUB RUNNER STARTING ---"

# 2. Pre-fetch PAT for the shutdown script (to avoid gcloud overhead during preemption)
# The runner service account needs secretmanager.secretAccessor role.
gcloud secrets versions access latest --secret="github-pat" --project="$PROJECT_ID" > /home/runner/.github-pat
chmod 600 /home/runner/.github-pat
chown runner:runner /home/runner/.github-pat

cd /home/runner/actions-runner

# 3. Configure
echo "--- Configuring ---"
# Clean up old state if it exists to allow re-registration
rm -f .runner .credentials .credentials_rsaparams
sudo -u runner ./config.sh --url "${REPO_URL}" --token "${RUNNER_TOKEN}" --unattended --labels gcp-spot-runner --replace

# 4. Run in background and monitor
echo "--- Running ---"
# Run the runner in the background
sudo -u runner ./run.sh &
RUNNER_PID=$!

echo "--- Starting Idle Monitor ---"
# Set custom idle timeouts per runner
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/name")
INSTANCE_ZONE=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" | awk -F/ '{print $NF}')

if [ "$INSTANCE_NAME" == "gh-static-runner-1" ]; then
    MAX_IDLE=60
elif [ "$INSTANCE_NAME" == "gh-static-runner-2" ]; then
    MAX_IDLE=30
else
    MAX_IDLE=10
fi

echo "Idle timeout set to ${MAX_IDLE}m for ${INSTANCE_NAME}"

IDLE_COUNT=0
CURRENT_STATE="booting"

# Function to update label with retry
update_state() {
    local new_state=$1
    if [ "$CURRENT_STATE" != "$new_state" ]; then
        echo "Updating runner-state from $CURRENT_STATE to $new_state..."
        if gcloud compute instances add-labels "$INSTANCE_NAME" --zone="$INSTANCE_ZONE" --labels="runner-state=$new_state" --project="$PROJECT_ID" --quiet; then
            CURRENT_STATE=$new_state
        else
            echo "Warning: Failed to update label to $new_state."
        fi
    fi
}

while true; do
    sleep 60
    
    if pgrep -f "Runner.Worker" > /dev/null; then
        echo "Runner is busy. Resetting idle counter."
        IDLE_COUNT=0
        update_state "busy"
    else
        IDLE_COUNT=$((IDLE_COUNT + 1))
        
        # After 1 minute of true idleness, flag as idle for the provisioner
        if [ $IDLE_COUNT -ge 1 ]; then
            update_state "idle"
        fi

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

echo "--- Shutting Down and Stopping Self ---"
gcloud compute instances stop "$INSTANCE_NAME" --zone="$INSTANCE_ZONE" --project="$PROJECT_ID" --quiet
