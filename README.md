# dotfiles

> **Warning:** This repo is a personal chezmoi configuration that writes directly to your home directory. Running `chezmoi init --apply` will overwrite files like `~/.gitconfig`, `~/.claude.json`, and others. It also runs a bootstrap script that installs software and modifies system services. **Do not apply blindly** — review the source files and `.chezmoi.toml.tmpl` first, and use `chezmoi diff` to preview changes before applying.

Portable, repeatable dev environment managed by [chezmoi](https://www.chezmoi.io/) with secrets from [Bitwarden](https://bitwarden.com/).

## What's Managed

| Target File | chezmoi Source | Type |
|---|---|---|
| `~/.claude/config.json` | `dot_claude/config.json.tmpl` | Template — API key from Bitwarden |
| `~/.claude/settings.json` | `dot_claude/settings.json` | Plain file — model preference |
| `~/.claude/CLAUDE.md` | `dot_claude/CLAUDE.md` | Plain file — global Claude Code instructions |
| `~/.claude.json` | `modify_dot_claude.json.ps1.tmpl` | Modify script — merges ADO MCP server config into existing file |
| `~/.gitconfig` | `dot_gitconfig.tmpl` | Template — git identity & credentials |
| `~/.config/git/ignore` | `dot_config/git/ignore` | Plain file — global gitignore |
| `~/cockpit/CLAUDE.md` | `cockpit/CLAUDE.md.tmpl` | Template — ADO task management workflow & agent orchestration |

### Not Managed (auto-generated / machine-specific)

- `~/.ssh/` — keys served by Bitwarden SSH agent (see setup below)
- `~/.git-credentials` — credential manager handles this
- `~/.vscode-server/` — VS Code remote server state
- `~/.npmrc`, `~/.yarnrc.yml` — contain feed tokens, managed by Azure Artifacts tooling
- `~/.cache/`, `~/.local/` (except chezmoi data) — caches

## Prerequisites

- Windows 11 with winget
- A Bitwarden account with the following vault entries:
  - **"Claude API Key"** — custom field `apiKey` containing your Anthropic API key
- GitHub account (for hosting this repo)

## New Machine Bootstrap

### 1. Install chezmoi

```powershell
winget install twpayne.chezmoi
```

### 2. Create Bitwarden Vault Entries (first time only)

#### "Claude API Key"

1. In your Bitwarden vault, create a new Login item named **Claude API Key**
2. Add a **Custom Field** (type: Hidden):
   - Name: `apiKey`
   - Value: your Anthropic API key (starts with `sk-ant-...`)

#### "GitHub SSH Key"

1. In your Bitwarden vault, create a new **SSH Key** item (native item type, not Login or Secure Note)
2. Name it **GitHub SSH Key**
3. Either generate a new key pair in Bitwarden or import an existing private key
4. Copy the public key from the vault entry for use in step 3 below

### 3. Set up Bitwarden SSH agent

The Bitwarden SSH agent serves keys directly from the vault — the private key never touches disk.

#### Enable the SSH agent in Bitwarden desktop

1. Open the Bitwarden desktop app and log in
2. Go to **Settings → SSH Agent**
3. Enable the SSH agent toggle

#### Add your SSH key to GitHub

1. Copy the public key from your **GitHub SSH Key** vault entry
2. Go to https://github.com/settings/ssh/new and add the public key
3. Verify authentication:

```bash
ssh -T git@github.com
```

You should see: `Hi <username>! You've successfully authenticated...`

### 4. Clone dotfiles and apply

```bash
chezmoi init --apply alwaibel_microsoft/dotfiles
```

This single command will:
- Clone this repo into `~/.local/share/chezmoi`
- Prompt you for your corporate email, Azure AD tenant ID, and Azure DevOps org name (stored locally, only asked once)
- Run the bootstrap script (`run_once_before_install-and-setup.ps1`) which automatically:
  - Installs Bitwarden desktop, Bitwarden CLI, and Azure CLI via winget
  - Adds the Azure DevOps CLI extension
  - Disables the Windows OpenSSH agent (Bitwarden SSH agent replaces it)
  - Prompts you to log in to Bitwarden (if not already logged in)
- Unlock Bitwarden and render templates with secrets injected
- Apply everything to your home directory

### 5. Verify

```bash
# Check chezmoi health
chezmoi doctor

# Preview what would change (without applying)
chezmoi diff

# Apply with verbose output
chezmoi apply -v
```

### 6. Test Azure DevOps MCP

Open a new Claude Code session. You should see Azure DevOps MCP tools available. Try asking Claude to list your assigned work items.

## Day-to-Day Usage

```bash
# Pull latest dotfiles from remote and apply
chezmoi update

# See what would change before applying
chezmoi diff

# Edit a managed file (opens in editor, auto-updates source)
chezmoi edit ~/.gitconfig

# Add a new file to chezmoi management
chezmoi add ~/.some-new-config

# After editing source files directly, apply changes
chezmoi apply -v
```

## How Secrets Work

Templates (`.tmpl` files) use chezmoi's Bitwarden integration to pull secrets at apply time:

```
{{ (bitwardenFields "item" "Claude API Key").apiKey.value }}
```

Secrets are **never stored in this repo**. They exist only in your Bitwarden vault and in the rendered target files on your machine.

chezmoi's `[bitwarden.secrets] unlock = "auto"` config means it will automatically prompt you to unlock your vault when needed during `chezmoi apply`.

## Updating Secrets

If you rotate an API key:

1. Update the value in your Bitwarden vault
2. Run `bw sync` to pull the latest vault data to the CLI
3. Run `chezmoi apply -v` to re-render templates with the new values

Azure DevOps auth uses `az login` (OAuth) instead of a PAT, so there's nothing to rotate — just make sure your `az` session is active.
