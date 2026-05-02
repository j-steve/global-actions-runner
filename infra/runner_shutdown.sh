#!/bin/bash
# This script runs during the 30-second preemption grace period.

# 1. Fetch necessary info
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/name")
INSTANCE_ZONE=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" | awk -F/ '{print $NF}')
PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id")
REPO_URL=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/github_repo")
PAT=$(cat /home/runner/.github-pat)

# Extract owner/repo from URL
OWNER_REPO=$(echo $REPO_URL | sed 's|https://github.com/||')

echo "Preemption detected for $INSTANCE_NAME. Cleaning up GitHub..."

# 2. Mark state as preempted in labels so the provisioner knows
gcloud compute instances add-labels "$INSTANCE_NAME" --zone="$INSTANCE_ZONE" --labels="runner-state=preempted" --project="$PROJECT_ID" --quiet

# 3. Find the Runner ID by name and DELETE it from GitHub
# Deleting the runner while a job is active causes GitHub to fail the job immediately.
RUNNER_ID=$(curl -s -X GET -H "Authorization: token $PAT" -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/$OWNER_REPO/actions/runners" | \
    jq -r ".runners[] | select(.name == \"$INSTANCE_NAME\") | .id")

if [ -n "$RUNNER_ID" ] && [ "$RUNNER_ID" != "null" ]; then
    echo "Removing runner ID $RUNNER_ID from GitHub..."
    curl -s -X DELETE -H "Authorization: token $PAT" -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$OWNER_REPO/actions/runners/$RUNNER_ID"
fi
