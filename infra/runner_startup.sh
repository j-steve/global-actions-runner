#!/bin/bash
set -ex

# --- ZOMBIE PREVENTION: Failure Trap ---
# If any command fails, we want the VM to shut itself down immediately.
# This prevents it from staying 'RUNNING' in GCP while being 'Offline' in GitHub.
# A stopped VM is visible to the Cloud Function as 'TERMINATED', which triggers a fresh start.
failure_handler() {
  local exit_code=$?
  local line_no=$1
  echo "--- ERROR: Startup script failed at line $line_no with exit code $exit_code. ---"
  echo "--- Shutting down to avoid zombie state. ---"
  sleep 10 # Give serial logs a moment to flush
  sudo poweroff || gcloud compute instances stop "$INSTANCE_NAME" --zone="$INSTANCE_ZONE" --project="$PROJECT_ID" --quiet || true
}
trap 'failure_handler $LINENO' ERR

PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id")
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/name")
INSTANCE_ZONE=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" | awk -F/ '{print $NF}')

# --- DISK HYGIENE & JANITOR ---
echo "--- Starting persistent-friendly disk janitor ---"

# 1. Clear temporary directories and runner diagnostics
rm -rf /tmp/* /var/tmp/* /home/runner/actions-runner/_diag/* || true

# 2. Clear Docker container logs
find /var/lib/docker/containers/ -type f -name "*.log" -delete || true

# 3. Clean stopped containers, dangling networks, and dangling volumes from previous test runs
docker container prune -f || true
docker network prune -f || true
docker volume prune -f || true
docker image prune -f || true

# 4. Cap system logs to 100MB
journalctl --vacuum-size=100M || true

# 5. Cap Bazel disk cache
if [ -d "/home/runner/.cache/bazel-disk-cache" ]; then
    find /home/runner/.cache/bazel-disk-cache -type f -mtime +3 -delete 2>/dev/null || true
fi

# 6. Dynamic Disk Threshold Check (calibrated for 50GB disk)
DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
echo "Current root disk usage: ${DISK_USAGE}%"

if [ "$DISK_USAGE" -gt 70 ]; then
    echo "Disk usage is elevated (${DISK_USAGE}% > 70%). Pruning workspace, BuildKit, and older Bazel cache..."
    rm -rf /home/runner/actions-runner/_work/* || true
    docker builder prune --keep-storage=5GB -f || true
    find /home/runner/.cache/bazel-disk-cache -type f -mtime +1 -delete 2>/dev/null || true
fi

DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$DISK_USAGE" -gt 85 ]; then
    echo "CRITICAL: Disk usage still high (${DISK_USAGE}% > 85%). Performing deep cleanup..."
    docker system prune -af --volumes || true
    rm -rf /home/runner/actions-runner/_work/* || true
    rm -rf /home/runner/.cache/bazel-disk-cache/* || true
fi

echo "--- Disk janitor complete. Current usage: $(df -h / | awk 'NR==2 {print $5}') ---"

# 0. Set initial state immediately to avoid zombie labels
gcloud compute instances add-labels "$INSTANCE_NAME" --zone="$INSTANCE_ZONE" --labels="runner-state=booting" --project="$PROJECT_ID" --quiet || true

echo "--- GITHUB RUNNER STARTING ---"

# 1. Fetch Repository URL (from metadata or default)
REPO_URL=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/github_repo" 2>/dev/null || true)
if [ -z "$REPO_URL" ] || [[ "$REPO_URL" == *"<html>"* ]] || [[ "$REPO_URL" == *"404"* ]]; then
    REPO_URL="https://github.com/j-steve/bellhop"
fi
OWNER_REPO=$(echo "$REPO_URL" | sed 's|https://github.com/||')
echo "Target repository: $OWNER_REPO"

# 2. Fetch GitHub PAT from Secret Manager (used for self-registration and shutdown deregistration)
echo "--- Fetching GitHub PAT from Secret Manager ---"
if ! gcloud secrets versions access latest --secret="github-pat" --project="$PROJECT_ID" > /home/runner/.github-pat; then
    echo "CRITICAL: Failed to retrieve github-pat from Secret Manager. Shutting down."
    sudo poweroff || gcloud compute instances stop "$INSTANCE_NAME" --zone="$INSTANCE_ZONE" --project="$PROJECT_ID" --quiet
    exit 1
fi
chmod 600 /home/runner/.github-pat
chown runner:runner /home/runner/.github-pat
PAT=$(cat /home/runner/.github-pat)

# 3. Mint fresh short-lived GitHub Runner Registration Token directly from GitHub API
echo "--- Minting fresh registration token from GitHub API ---"
RUNNER_TOKEN=$(curl -s -f -X POST \
    -H "Authorization: token $PAT" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${OWNER_REPO}/actions/runners/registration-token" | jq -r .token)

if [ -z "$RUNNER_TOKEN" ] || [ "$RUNNER_TOKEN" == "null" ]; then
    echo "CRITICAL: Failed to obtain registration token from GitHub API. Shutting down."
    sudo poweroff || gcloud compute instances stop "$INSTANCE_NAME" --zone="$INSTANCE_ZONE" --project="$PROJECT_ID" --quiet
    exit 1
fi
echo "Successfully obtained registration token from GitHub API."

# 4. Ensure global tools (Bazelisk/Bazel & Docker registry auth)
if ! command -v bazel &>/dev/null; then
    echo "--- Installing bazelisk to /usr/local/bin/bazel ---"
    curl -fsSL https://github.com/bazelbuild/bazelisk/releases/download/v1.29.0/bazelisk-linux-amd64 -o /usr/local/bin/bazel || true
    chmod +x /usr/local/bin/bazel || true
    ln -sf /usr/local/bin/bazel /usr/local/bin/bazelisk || true
fi
if ! command -v trufflehog &>/dev/null; then
    echo "--- Installing trufflehog to /usr/local/bin/trufflehog ---"
    curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sh -s -- -b /usr/local/bin || true
fi
if ! command -v uv &>/dev/null; then
    echo "--- Installing uv to /usr/local/bin/uv ---"
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh || true
fi
sudo -u runner gcloud auth configure-docker us-central1-docker.pkg.dev --quiet || true

# Setup user directories and ensure clean permissions (avoid slow recursive chown on large cache tree)
rm -f /home/runner/.local/bin/bazel /home/runner/.local/bin/bazelisk || true
mkdir -p /home/runner/.local/bin /home/runner/.cache /home/runner/.config
chown -R runner:runner /home/runner/.local /home/runner/.config || true
chown runner:runner /home/runner/.cache || true

# 4. Setup Post-Job Cleanup Hook (Runs immediately when any job completes)
cat <<'HOOK_EOF' > /home/runner/cleanup_job_hook.sh
#!/bin/bash
echo "=== Post-Job Cleanup Hook Triggered ==="
rm -rf /home/runner/actions-runner/_work/* || true
rm -rf /tmp/* || true
docker container prune -f || true
docker volume prune -f || true
docker network prune -f || true

# Prune stale Bazel disk cache (>3 days old)
if [ -d "/home/runner/.cache/bazel-disk-cache" ]; then
    find /home/runner/.cache/bazel-disk-cache -type f -mtime +3 -delete 2>/dev/null || true
    # If root disk usage exceeds 75%, prune entries older than 1 day
    USAGE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    if [ "$USAGE" -gt 75 ]; then
        find /home/runner/.cache/bazel-disk-cache -type f -mtime +1 -delete 2>/dev/null || true
    fi
fi
echo "=== Post-Job Cleanup Completed ==="
HOOK_EOF
chmod +x /home/runner/cleanup_job_hook.sh
chown runner:runner /home/runner/cleanup_job_hook.sh

cd /home/runner/actions-runner

# Export environment variables into runner .env so EVERY job/step has HOME and hook defined
cat <<ENV_EOF > /home/runner/actions-runner/.env
HOME=/home/runner
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/home/runner/cleanup_job_hook.sh
PATH=/home/runner/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV_EOF
chown runner:runner /home/runner/actions-runner/.env
export HOME=/root

# 5. Configure
echo "--- Configuring ---"
# --- ZOMBIE PREVENTION: State Cleanup ---
rm -f .runner .credentials .credentials_rsaparams .runner_migrated

sudo -u runner ./config.sh --url "${REPO_URL}" --token "${RUNNER_TOKEN}" --unattended --labels gcp-spot-runner --replace

# 6. Run in background and monitor
echo "--- Running ---"
# Run the runner in the background
sudo -E -u runner ./run.sh &
RUNNER_PID=$!

echo "--- Starting Idle Monitor ---"
# Set custom idle timeouts per runner (15 minutes for static runners)
if [ "$INSTANCE_NAME" == "gh-static-runner-1" ]; then
    MAX_IDLE=15
elif [ "$INSTANCE_NAME" == "gh-static-runner-2" ]; then
    MAX_IDLE=15
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
        if gcloud compute instances add-labels "$INSTANCE_NAME" --zone="$INSTANCE_ZONE" --labels="runner-state=$new_state" --project="$PROJECT_ID" --quiet 2>/dev/null; then
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
# Prefer ACPI OS poweroff so shutdown never fails on IAM / gcloud credential issues
sudo poweroff || gcloud compute instances stop "$INSTANCE_NAME" --zone="$INSTANCE_ZONE" --project="$PROJECT_ID" --quiet
