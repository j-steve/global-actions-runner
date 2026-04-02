#!/bin/bash
set -ex

# This script creates the optimized "base image" for the GitHub Runners.
# It installs Docker, pre-pulls integration test images, and sets up the runner environment.
# Now includes pre-installed Python 3.11 dependencies to speed up CI.

PROJECT_ID=$(gcloud config get-value project)
ZONE="us-central1-a"
BUILDER_NAME="image-builder-v$(date +%s)"
# Use a version number that we can easily increment
IMAGE_NAME="github-runner-base-v4"

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
apt-get install -y curl jq libatomic1 ca-certificates gnupg lsb-release software-properties-common

# Install Python 3.11
add-apt-repository ppa:deadsnakes/ppa -y
apt-get update
apt-get install -y python3.11 python3.11-venv python3.11-dev python3-pip

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

# Pre-install Python dependencies globally to be cached
# We use --ignore-installed to avoid issues with pre-installed system packages like 'blinker'
python3.11 -m pip install --upgrade pip
python3.11 -m pip install --ignore-installed \
    fastapi==0.135.1 \
    google-api-python-client==2.192.0 \
    google-auth==2.49.0 \
    google-auth-httplib2==0.3.0 \
    google-auth-oauthlib==1.3.0 \
    google-cloud-aiplatform==1.141.0 \
    google-cloud-firestore==2.25.0 \
    google-cloud-storage==3.9.0 \
    google-cloud-tasks==2.21.0 \
    gunicorn==25.1.0 \
    httpx==0.28.1 \
    langchain-core==1.2.18 \
    langchain-google-vertexai==3.2.2 \
    langgraph==1.1.1 \
    langgraph-checkpoint==4.0.1 \
    pydantic==2.12.5 \
    pydantic-settings==2.13.1 \
    python-dateutil==2.9.0.post0 \
    python-dotenv==1.2.2 \
    PyYAML==6.0.3 \
    requests==2.33.0 \
    tavily-python==0.7.23 \
    twilio==9.10.3 \
    uvicorn==0.41.0 \
    uvicorn-worker==0.4.0 \
    croniter aiortc chatgpt_md_converter functions_framework starlette google-cloud-logging python-multipart==0.0.22 Pillow \
    pytest pytest-asyncio pytest-cov pytest-mock pytest-socket pytest-benchmark pytest-recording pytest-codspeed \
    testcontainers[google-cloud-firestore,redis] wiremock ruff pyright pip-audit bandit deptry pipdeptree pipreqs responses

mkdir -p /home/runner/actions-runner && cd /home/runner/actions-runner
LATEST_VERSION_TAG=$(curl -s "https://api.github.com/repos/actions/runner/releases/latest" | jq -r ".tag_name")
LATEST_VERSION=${LATEST_VERSION_TAG#v}
RUNNER_TAR_BALL="actions-runner-linux-x64-${LATEST_VERSION}.tar.gz"
curl -o "${RUNNER_TAR_BALL}" -L "https://github.com/actions/runner/releases/download/${LATEST_VERSION_TAG}/${RUNNER_TAR_BALL}"
tar xzf ./"${RUNNER_TAR_BALL}" --no-same-owner
chown -R runner:runner /home/runner

echo "--- IMAGE BUILDER FINISHED ---"
')

echo "--- Waiting for setup to finish (approx 5-10 minutes due to pip installs) ---"
# Poll for the finish message in serial port. Fixed grep bug.
while true; do
  if gcloud compute instances get-serial-port-output "$BUILDER_NAME" --zone="$ZONE" | grep -q "IMAGE BUILDER FINISHED"; then
    break
  fi
  sleep 30
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
