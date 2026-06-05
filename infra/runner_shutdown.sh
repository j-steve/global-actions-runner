#!/bin/bash
# This script runs during the 30-second preemption grace period.

LOG_NAME="runner-shutdown"

log_info() {
    local msg="$1"
    echo "[$(date)] INFO: $msg"
}

log_error() {
    local msg="$1"
    echo "[$(date)] ERROR: $msg"
}

# 1. Fetch necessary info
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/name")
INSTANCE_ZONE=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" | awk -F/ '{print $NF}')
PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id")
REPO_URL=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/github_repo")

log_info "--- Shutdown script triggered ---"

if [ ! -f /home/runner/.github-pat ]; then
    log_error "PAT not found at /home/runner/.github-pat"
    exit 1
fi
PAT=$(cat /home/runner/.github-pat)

# Extract owner/repo from URL
OWNER_REPO=$(echo $REPO_URL | sed 's|https://github.com/||')

log_info "Preemption or shutdown detected for $INSTANCE_NAME. Cleaning up GitHub..."

# 3. Find the Runner ID by name and DELETE it from GitHub
RUNNER_ID=$(curl -s -X GET -H "Authorization: token $PAT" -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/$OWNER_REPO/actions/runners" | \
    jq -r ".runners[] | select(.name == \"$INSTANCE_NAME\") | .id")

if [ -n "$RUNNER_ID" ] && [ "$RUNNER_ID" != "null" ]; then
    log_info "Removing runner ID $RUNNER_ID from GitHub..."
    DELETE_RESPONSE=$(curl -s -X DELETE -H "Authorization: token $PAT" -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$OWNER_REPO/actions/runners/$RUNNER_ID")
    log_info "GitHub delete response: $DELETE_RESPONSE"
else
    log_info "No Runner ID found for $INSTANCE_NAME in GitHub."
fi

log_info "--- Shutdown script finished ---"

