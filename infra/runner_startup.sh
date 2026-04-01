#!/bin/bash
set -ex

RUNNER_TOKEN=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/github_token")
REPO_URL=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/github_repo")

echo "--- GITHUB RUNNER STARTING ---"

cd /home/runner/actions-runner

echo "--- Configuring ---"
sudo -u runner ./config.sh --url "${REPO_URL}" --token "${RUNNER_TOKEN}" --ephemeral --unattended --labels gcp-spot-runner

echo "--- Running ---"
sudo -u runner ./run.sh

echo "--- Shutting Down ---"
shutdown -h now
