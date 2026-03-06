# dotfiles

> **Warning:** This repo is a personal chezmoi configuration that writes directly to your home directory. Running `chezmoi init --apply` will overwrite files like `~/.gitconfig`, `~/.claude.json`, and others. It also runs a bootstrap script that installs software and modifies system services. **Do not apply blindly** — review the source files and `.chezmoi.toml.tmpl` first, and use `chezmoi diff` to preview changes before applying.

Portable, repeatable dev environment managed by [chezmoi](https://www.chezmoi.io/) with secrets from [Bitwarden](https://bitwarden.com/). Works on both Windows and WSL/Linux.

## Prerequisites

- **Windows**: Windows 11 with winget
- **WSL/Linux**: Ubuntu (or Debian-based distro)
- A Bitwarden account with the following vault entries:
  - **"Claude API Key"** — custom field `apiKey` containing your Anthropic API key
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

```bash
chezmoi init --apply alexwaibel/dotfiles-work
```

This will:
- Prompt for your corporate email, Azure AD tenant ID, and ADO config (stored locally, only asked once)
- Run the platform-specific bootstrap script which installs:
  - **Windows**: Bitwarden (desktop + CLI), Azure CLI, nvm-windows, Node.js LTS, WSL with Ubuntu, Claude Code — via winget + native installers. Also disables the Windows OpenSSH agent (Bitwarden replaces it).
  - **Linux/WSL**: curl, jq, nvm, Node.js LTS, Bitwarden CLI (via npm), Azure CLI, Claude Code — via apt + native installers.
- Prompt for Bitwarden login (if not already authenticated)
- Render templates with secrets from Bitwarden and apply to home directory

### 3. Set up Bitwarden SSH agent

The Bitwarden SSH agent serves keys directly from the vault — the private key never touches disk.

1. Open the Bitwarden desktop app → **Settings → SSH Agent** → enable
2. Add the public key from your **GitHub SSH Key** vault entry to https://github.com/settings/ssh/new
3. Verify: `ssh -T git@github.com`

### 4. Verify

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
