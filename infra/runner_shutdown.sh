#!/bin/bash
# This script runs during the 30-second preemption grace period.

LOG_FILE="/var/log/runner-shutdown.log"
echo "[$(date)] --- Shutdown script triggered ---" | tee -a $LOG_FILE

# 1. Fetch necessary info
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/name")
INSTANCE_ZONE=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" | awk -F/ '{print $NF}')
PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id")
REPO_URL=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/github_repo")

if [ ! -f /home/runner/.github-pat ]; then
    echo "[$(date)] ERROR: PAT not found at /home/runner/.github-pat" | tee -a $LOG_FILE
    exit 1
fi
PAT=$(cat /home/runner/.github-pat)

# Extract owner/repo from URL
OWNER_REPO=$(echo $REPO_URL | sed 's|https://github.com/||')

echo "[$(date)] Preemption detected for $INSTANCE_NAME. Cleaning up GitHub..." | tee -a $LOG_FILE

# 2. Mark state as preempted in labels so the provisioner knows
if gcloud compute instances add-labels "$INSTANCE_NAME" --zone="$INSTANCE_ZONE" --labels="runner-state=preempted" --project="$PROJECT_ID" --quiet; then
    echo "[$(date)] Successfully updated instance label to preempted." | tee -a $LOG_FILE
else
    echo "[$(date)] WARNING: Failed to update instance label." | tee -a $LOG_FILE
fi

# 3. Find the Runner ID by name and DELETE it from GitHub
RUNNER_ID=$(curl -s -X GET -H "Authorization: token $PAT" -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/$OWNER_REPO/actions/runners" | \
    jq -r ".runners[] | select(.name == \"$INSTANCE_NAME\") | .id")

if [ -n "$RUNNER_ID" ] && [ "$RUNNER_ID" != "null" ]; then
    echo "[$(date)] Removing runner ID $RUNNER_ID from GitHub..." | tee -a $LOG_FILE
    DELETE_RESPONSE=$(curl -s -X DELETE -H "Authorization: token $PAT" -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$OWNER_REPO/actions/runners/$RUNNER_ID")
    echo "[$(date)] Delete response: $DELETE_RESPONSE" | tee -a $LOG_FILE
else
    echo "[$(date)] No Runner ID found for $INSTANCE_NAME in GitHub." | tee -a $LOG_FILE
fi

echo "[$(date)] --- Shutdown script finished ---" | tee -a $LOG_FILE
