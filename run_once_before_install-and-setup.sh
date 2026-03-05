#!/bin/bash
# chezmoi run_once_before script — first-time WSL/Linux bootstrap
# Installs nvm, Node.js, Azure CLI, Bitwarden CLI, and logs into Bitwarden.

set -euo pipefail

# --- 1. Install apt packages ---

sudo apt-get update -qq
sudo apt-get install -y -qq curl jq unzip

# --- 2. Install nvm and Node.js LTS ---

export NVM_DIR="${HOME}/.nvm"

if [ ! -d "$NVM_DIR" ]; then
    echo "Installing nvm ..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
else
    echo "nvm already installed."
fi

# Load nvm for this session
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

if ! nvm ls --no-colors lts/* &>/dev/null; then
    echo "Installing Node.js LTS ..."
    nvm install --lts
else
    echo "Node.js LTS already installed."
fi

# --- 3. Install Bitwarden CLI via npm ---

if command -v bw &>/dev/null; then
    echo "Bitwarden CLI is already installed."
else
    echo "Installing Bitwarden CLI via npm ..."
    npm install -g @bitwarden/cli
fi

# --- 4. Install Azure CLI ---

if command -v az &>/dev/null; then
    echo "Azure CLI is already installed."
else
    echo "Installing Azure CLI ..."
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
fi

# --- 5. Install az devops extension ---

echo "Adding Azure DevOps CLI extension ..."
az extension add --name azure-devops --yes 2>/dev/null || true
echo "azure-devops extension ready."

# --- 6. Install Claude Code ---

if command -v claude &>/dev/null; then
    echo "Claude Code is already installed."
else
    echo "Installing Claude Code ..."
    curl -fsSL https://claude.ai/install.sh | bash
fi

# --- 7. Bitwarden login ---

echo "Checking Bitwarden status ..."
bw_status=$(bw status 2>/dev/null | jq -r '.status' || echo "not-installed")

if [ "$bw_status" = "unauthenticated" ]; then
    echo "Not logged in to Bitwarden. Starting interactive login ..."
    bw login
fi

if [ "$bw_status" = "locked" ]; then
    echo "Unlocking Bitwarden vault ..."
    BW_SESSION=$(bw unlock --raw)
    export BW_SESSION
fi

echo "Bootstrap complete."
