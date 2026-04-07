sudo apt update
sudo apt install -y tmux curl
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g @google/gemini-cli

# Setup Vertex API for Gemini CLI.
echo 'export GOOGLE_CLOUD_PROJECT=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id")' >> ~/.bashrc
echo 'export GOOGLE_CLOUD_LOCATION="global"' >> ~/.bashrc
echo 'export GOOGLE_GENAI_USE_VERTEXAI=true' >> ~/.bashrc
source ~/.bashrc

# Setup Gemini CLI settings.
mkdir -p ~/.gemini
cat <<EOF > ~/.gemini/settings.json
{
  "model": {
    "name": "gemini-3-flash-preview"
  }
}
EOF

# Enable TMUX scrolling.
echo "set -g mouse on" >> ~/.tmux.conf
tmux source-file ~/.tmux.conf
