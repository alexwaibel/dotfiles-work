# chezmoi run_once_before script — first-time machine bootstrap
# Installs tools via winget, configures the SSH agent, and logs into Bitwarden.

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# --- 1. Install winget packages (idempotent) ---

$packages = @(
    'Bitwarden.Bitwarden'
    'Bitwarden.CLI'
    'Microsoft.AzureCLI'
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

# --- 2. Install az devops extension ---

Write-Host 'Adding Azure DevOps CLI extension ...'
az extension add --name azure-devops --yes 2>$null
Write-Host 'azure-devops extension ready.'

# --- 3. Configure OpenSSH Authentication Agent ---

Write-Host 'Configuring OpenSSH Authentication Agent ...'
$sshAgent = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
if ($sshAgent) {
    if ($sshAgent.StartType -ne 'Automatic') {
        Set-Service -Name ssh-agent -StartupType Automatic
        Write-Host '  StartupType set to Automatic.'
    }
    if ($sshAgent.Status -ne 'Running') {
        Start-Service -Name ssh-agent
        Write-Host '  Service started.'
    }
    Write-Host 'ssh-agent is running.'
} else {
    Write-Warning 'ssh-agent service not found — OpenSSH may not be installed.'
}

# --- 4. Bitwarden login ---

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
