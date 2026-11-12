# dotfiles

> **Warning:** This repo is a personal chezmoi configuration that writes directly to your home directory. Running `chezmoi init --apply` will overwrite files like `~/.gitconfig`, `~/.copilot/settings.json`, and others. It also runs a bootstrap script that installs software and modifies system services. **Do not apply blindly** — review the source files and `.chezmoi.toml.tmpl` first, and use `chezmoi diff` to preview changes before applying.

Portable, repeatable dev environment managed by [chezmoi](https://www.chezmoi.io/) with secrets from [Bitwarden](https://bitwarden.com/). Works on both Windows and WSL/Linux.

## Repository Layout

```text
.chezmoidata/       Shared template data and version pins
.chezmoiscripts/    Ordered first-run and change-triggered lifecycle scripts
dot_*/              Files and directories managed into $HOME
tests/run.sh        Complete local validation entry point
```

Lifecycle scripts are intentionally split by concern:

- `run_once_before_10_*` installs platform tools before managed files are applied.
- `run_once_after_80_*` configures the user environment after managed files exist.
- `run_onchange_after_*` performs idempotent synchronization when its inputs change.

Application-specific tests stay beside their implementation. `tests/run.sh`
discovers and invokes them along with template parsing, ShellCheck, PowerShell
parsing, JSON validation, MCP inventory checks, and dependency auditing.

Run the complete suite before committing:

```bash
bash tests/run.sh
```

## Work Management

Copilot skills query live systems rather than maintaining a parallel Markdown
state database:

- ADO owns sprint, priority, state, and work-item relationships.
- Git owns branches, commits, and worktrees.
- PR providers own review state.
- Docker Sandboxes owns VM state; Git bundles and staged files carry results.
- Copilot session history provides prior-session context.

`standup`, `daily`, `status`, and `sandbox-work` compose these sources
on demand. There is no cockpit state file or browser handoff queue.

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
  - **Windows**: Bitwarden (desktop + CLI), Azure CLI, AzureAuth, Docker Sandboxes, Git, GitHub CLI, nvm-windows, Node.js LTS, WSL with Ubuntu, GitHub Copilot CLI — via winget + native installers. Also disables the Windows OpenSSH agent (Bitwarden replaces it).
  - **Linux/WSL**: curl, Git, jq, nvm, Node.js LTS, Bitwarden CLI (via npm), Azure CLI, AzureAuth, GitHub Copilot CLI — via apt + native installers.
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

### 5. Set up Docker Sandboxes

Run these one-time commands in Windows PowerShell:

```powershell
sbx login
gh auth login
sbx secret set github `
  --command 'gh auth token --hostname github.com' `
  --refresh on-demand
sbx secret set copilot `
  --command 'gh auth token --hostname github.com' `
  --refresh on-demand
sbx policy init balanced
```

The `copilot` service secret is required by Docker's Copilot kit. The token stays in the
Windows credential store and is injected by Docker's proxy rather than copied into the VM.
The Windows user-configuration script disables sandbox SSH-agent forwarding, host-browser
opening, FUSE/SYS_ADMIN, and Docker telemetry, then restarts the daemon. Those managed
settings are intentionally not repeated as manual setup commands here.
Chezmoi also installs a narrow Windows Git compatibility shim for Docker
Sandboxes v0.51 with Git 2.56. It changes only Docker's invalid
`-c core.hooksPath=` override to `core.hooksPath=NUL`, enabling native clone mode
for allowlisted WSL repositories.

The WSL `sbx-host` MCP bridge fills only the current WSL integration gaps. Invoke the
`sandbox-work` skill from a Copilot session; it uses schema-constrained host tools for seed,
noninteractive Copilot dispatch, export, and exceptional follow-up sync. Seed restores
detected Azure Artifacts dependencies before the agent starts.
Azure authentication runs through Windows PowerShell so Conditional Access uses the signed-in
Windows session rather than launching a browser inside WSL.
Interactive attachment remains available for diagnostics:

```powershell
sbx run --name wi-<work-item>-vm
```

Use native `sbx` commands for policy, diagnostics, lifecycle, and removal. Do not grant the
local Copilot sandbox `/init` or `/run/WSL`; those paths permit arbitrary Windows process
launch.

### 6. Verify

```bash
chezmoi doctor
chezmoi diff
chezmoi apply -v
sbx diagnose
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
