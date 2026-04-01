#!/bin/bash
set -ex

# This script creates the optimized "base image" for the GitHub Runners.
# It installs Docker, pre-pulls integration test images, and sets up the runner environment.

PROJECT_ID=$(gcloud config get-value project)
ZONE="us-central1-a"
BUILDER_NAME="image-builder-v$(date +%s)"
IMAGE_NAME="github-runner-base-v$(date +%Y%m%d)"

echo "--- Creating Builder Instance: $BUILDER_NAME ---"

gcloud compute instances create "$BUILDER_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type=e2-standard-2 \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=50GB \
    --metadata-from-file=startup-script=<(echo '#!/bin/bash
set -ex
apt-get update
apt-get install -y curl jq libatomic1 ca-certificates gnupg lsb-release

# Proper Docker Repo setup
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io

systemctl start docker || true

# Pre-pull integration test images to save time during CI runs
docker pull redis:7-alpine
docker pull mtlynch/firestore-emulator:latest
docker pull wiremock/wiremock:3.2.0

# Setup runner user and pre-download the Actions Runner binaries
if ! id "runner" &>/dev/null; then
    useradd -m runner
fi
usermod -aG docker runner

mkdir -p /home/runner/actions-runner && cd /home/runner/actions-runner
LATEST_VERSION_TAG=$(curl -s "https://api.github.com/repos/actions/runner/releases/latest" | jq -r ".tag_name")
LATEST_VERSION=${LATEST_VERSION_TAG#v}
RUNNER_TAR_BALL="actions-runner-linux-x64-${LATEST_VERSION}.tar.gz"
curl -o "${RUNNER_TAR_BALL}" -L "https://github.com/actions/runner/releases/download/${LATEST_VERSION_TAG}/${RUNNER_TAR_BALL}"
tar xzf ./"${RUNNER_TAR_BALL}" --no-same-owner
chown -R runner:runner /home/runner

echo "--- IMAGE BUILDER FINISHED ---"
')

echo "--- Waiting for setup to finish (approx 3 minutes) ---"
# Poll for the finish message in serial port
while true; do
  if gcloud compute instances get-serial-port-output "$BUILDER_NAME" --zone="$ZONE" | grep -q "--- IMAGE BUILDER FINISHED ---"; then
    break
  fi
  sleep 10
done

echo "--- Stopping Builder and Creating Image: $IMAGE_NAME ---"
gcloud compute instances stop "$BUILDER_NAME" --zone="$ZONE" --quiet
gcloud compute images create "$IMAGE_NAME" \
    --project="$PROJECT_ID" \
    --source-disk="$BUILDER_NAME" \
    --source-disk-zone="$ZONE" \
    --family=github-runner-base

echo "--- Cleaning up Builder Instance ---"
gcloud compute instances delete "$BUILDER_NAME" --zone="$ZONE" --quiet

echo "--- SUCCESS! Image created: $IMAGE_NAME ---"
echo "Update your infra/main.tf to point to this new image name."
