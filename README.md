# dotfiles

> **Warning:** This repo is a personal chezmoi configuration that writes directly to your home directory. Running `chezmoi init --apply` will overwrite files like `~/.gitconfig`, `~/.copilot/settings.json`, and others. It also runs a bootstrap script that installs software and modifies system services. **Do not apply blindly** — review the source files and `.chezmoi.toml.tmpl` first, and use `chezmoi diff` to preview changes before applying.

Portable, repeatable dev environment managed by [chezmoi](https://www.chezmoi.io/) with secrets from [Bitwarden](https://bitwarden.com/). Works on both Windows and WSL/Linux.

## Prerequisites

- **Windows**: Windows 11 with winget
- **WSL/Linux**: Ubuntu (or Debian-based distro)
- A Bitwarden account with the following vault entries:
  - **"GitHub SSH Key"** — SSH Key item (native type) for GitHub auth

## New Machine Bootstrap

### 1. Install chezmoi

**Windows (PowerShell):**
```powershell
winget install twpayne.chezmoi --accept-source-agreements --accept-package-agreements
```

**WSL/Linux:**
```bash
sh -c "$(curl -fsLS get.chezmoi.io)"
```

### 2. Clone dotfiles and apply

To avoid multiple Bitwarden prompts, log in and export the session first:

**Windows (PowerShell):**
```powershell
$env:BW_SESSION = (bw login --raw)
chezmoi init --apply alexwaibel/dotfiles-work
```

**WSL/Linux:**
```bash
export BW_SESSION=$(bw login --raw)
chezmoi init --apply alexwaibel/dotfiles-work
```

If you're already logged in but locked, use `bw unlock --raw` instead of `bw login --raw`.

This will:
- Prompt for your corporate email, Azure AD tenant ID, and ADO config (stored locally, only asked once)
- Run the platform-specific bootstrap script which installs:
  - **Windows**: Bitwarden (desktop + CLI), Azure CLI, nvm-windows, Node.js LTS, WSL with Ubuntu, GitHub Copilot CLI — via winget + native installers. Also disables the Windows OpenSSH agent (Bitwarden replaces it).
  - **Linux/WSL**: curl, jq, nvm, Node.js LTS, Bitwarden CLI (via npm), Azure CLI, GitHub Copilot CLI — via apt + native installers.
- Prompt for Bitwarden login (if not already authenticated)
- Extract the `alexwaibelmsft` SSH public key from the agent and configure `~/.ssh/config` so Git uses the correct key for GitHub
- Switch the chezmoi repo remote from HTTPS to SSH
- Render templates with secrets from Bitwarden and apply to home directory

### 3. Set up WSL

The Windows bootstrap installs WSL and Ubuntu, but first launch requires interactive user setup:

1. Open **Ubuntu** from the Start menu and create your Unix user account
2. Install chezmoi and apply dotfiles inside WSL:
   ```bash
   sh -c "$(curl -fsLS get.chezmoi.io)"
   chezmoi init --apply alexwaibel/dotfiles-work
   ```

### 4. Set up Bitwarden SSH agent

The Bitwarden SSH agent serves keys directly from the vault — the private key never touches disk. The bootstrap script automatically extracts the correct public key and configures `~/.ssh/config`, but the agent itself must be enabled manually:

1. Open the Bitwarden desktop app → **Settings → SSH Agent** → enable
2. Add the public keys from your GitHub SSH Key vault entries to https://github.com/settings/ssh/new
3. Verify: `ssh -T git@github.com`

### 5. Verify

```bash
chezmoi doctor
chezmoi diff
chezmoi apply -v
```

## Day-to-Day Usage

```bash
chezmoi update          # Pull latest dotfiles and apply
chezmoi diff            # Preview changes before applying
chezmoi edit ~/.gitconfig  # Edit managed file (auto-updates source)
chezmoi add ~/.newfile  # Add a new file to management
chezmoi apply -v        # Apply after editing source files directly
```

## How Secrets Work

Templates (`.tmpl` files) use chezmoi's Bitwarden integration to pull secrets at apply time. Secrets are **never stored in this repo** — they exist only in your Bitwarden vault and in rendered target files on your machine.

`[bitwarden.secrets] unlock = "auto"` in the chezmoi config means it will automatically prompt you to unlock your vault when needed.

To rotate a secret: update it in Bitwarden → `bw sync` → `chezmoi apply -v`.

Azure DevOps auth uses `az login` (OAuth), so there's nothing to rotate.
