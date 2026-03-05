# chezmoi run_once_before script — first-time machine bootstrap
# Installs tools via winget, disables the Windows SSH agent (Bitwarden provides its own), and logs into Bitwarden.

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# --- 1. Install winget packages (idempotent) ---

$packages = @(
    'Bitwarden.Bitwarden'
    'Bitwarden.CLI'
    'Microsoft.AzureCLI'
    'CoreyButler.NVMforWindows'
)

foreach ($pkg in $packages) {
    $installed = winget list --id $pkg --exact --accept-source-agreements 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing $pkg ..."
        winget install --id $pkg --exact --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw "Failed to install $pkg" }
    } else {
        Write-Host "$pkg is already installed."
    }
}

# Refresh PATH so newly-installed CLIs are available in this session
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

# --- 2. Install Node.js LTS via nvm ---

$nvmNode = nvm list 2>$null | Select-String '\*'
if (-not $nvmNode) {
    Write-Host 'Installing Node.js LTS via nvm ...'
    nvm install lts
    nvm use lts
} else {
    Write-Host "Node.js already installed: $($nvmNode.Line.Trim())"
}

# --- 3. Install az devops extension ---

Write-Host 'Adding Azure DevOps CLI extension ...'
az extension add --name azure-devops --yes 2>$null
Write-Host 'azure-devops extension ready.'

# --- 4. Disable Windows OpenSSH agent (Bitwarden SSH agent replaces it) ---

$sshAgent = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
if ($sshAgent -and ($sshAgent.Status -eq 'Running' -or $sshAgent.StartType -ne 'Disabled')) {
    Write-Host 'Disabling Windows OpenSSH Authentication Agent (Bitwarden provides its own) ...'
    Write-Host '  Requesting elevated permissions (UAC prompt) ...'
    $proc = Start-Process -Verb RunAs -FilePath powershell.exe -ArgumentList '-Command', 'Stop-Service ssh-agent -ErrorAction SilentlyContinue; Set-Service ssh-agent -StartupType Disabled' -Wait -PassThru
    if ($proc.ExitCode -eq 0) {
        Write-Host '  Windows ssh-agent stopped and disabled.'
    } else {
        Write-Warning 'Failed to disable ssh-agent — you may need to disable it manually from an admin shell.'
    }
} else {
    Write-Host 'Windows ssh-agent already disabled or not found.'
}

# --- 5. Install Claude Code ---

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host 'Claude Code is already installed.'
} else {
    Write-Host 'Installing Claude Code ...'
    Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
}

# --- 6. Bitwarden login ---

Write-Host 'Checking Bitwarden status ...'
$bwStatus = bw status 2>$null | ConvertFrom-Json

if ($bwStatus.status -eq 'unauthenticated') {
    Write-Host 'Not logged in to Bitwarden. Starting interactive login ...'
    bw login
    if ($LASTEXITCODE -ne 0) { throw 'Bitwarden login failed.' }
    $bwStatus = bw status | ConvertFrom-Json
}

if ($bwStatus.status -eq 'locked') {
    Write-Host 'Bitwarden vault is locked — chezmoi will prompt you to unlock when it renders templates.'
}

Write-Host 'Bootstrap complete.'
