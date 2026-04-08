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
# HOWEVER, if this is the last remaining live server in us-central1, it waits for 60 minutes.
IDLE_COUNT=0
BASE_MAX_IDLE=10 
EXTENDED_MAX_IDLE=60
MAX_IDLE=$BASE_MAX_IDLE

INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/name")
INSTANCE_ZONE=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" | awk -F/ '{print $NF}')
INSTANCE_REGION=$(echo "$INSTANCE_ZONE" | cut -d'-' -f1,2)

while true; do
    sleep 60
    
    if pgrep -f "Runner.Worker" > /dev/null; then
        echo "Runner is busy. Resetting idle counter."
        IDLE_COUNT=0
    else
        IDLE_COUNT=$((IDLE_COUNT + 1))
        
        # Check if we should extend the timeout (at the 10-minute mark or if already extended)
        if [ "$INSTANCE_REGION" == "us-central1" ] && [ $IDLE_COUNT -ge $BASE_MAX_IDLE ]; then
            # Find the YOUNGEST gh-runner instance in this region
            YOUNGEST_RUNNER=$(gcloud compute instances list --project="$PROJECT_ID" \
                --filter="name ~ ^gh-runner- AND zone ~ $INSTANCE_REGION" \
                --sort-by=~creationTimestamp \
                --format="value(name)" | head -n 1)
            
            if [ "$INSTANCE_NAME" == "$YOUNGEST_RUNNER" ]; then
                echo "Runner is the YOUNGEST in us-central1. Extending timeout to ${EXTENDED_MAX_IDLE}m."
                MAX_IDLE=$EXTENDED_MAX_IDLE
            else
                echo "Younger runner found ($YOUNGEST_RUNNER). Keeping 10m timeout."
                MAX_IDLE=$BASE_MAX_IDLE
            fi
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

echo "--- Shutting Down and Deleting Self ---"
gcloud compute instances delete "$INSTANCE_NAME" --zone="$INSTANCE_ZONE" --project="$PROJECT_ID" --quiet
