# First-time Windows user configuration. Runs after managed files are applied.

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$starshipInit = "if (Get-Command starship -ErrorAction SilentlyContinue) { Invoke-Expression (&starship init powershell) }"
$myDocs = [Environment]::GetFolderPath('MyDocuments')
$psProfiles = @(
    "$myDocs\WindowsPowerShell\profile.ps1"
    "$myDocs\PowerShell\profile.ps1"
)

foreach ($psProfile in $psProfiles) {
    $psProfileDir = Split-Path $psProfile
    if (-not (Test-Path $psProfileDir)) {
        New-Item -ItemType Directory -Path $psProfileDir | Out-Null
    }
    if (-not (Test-Path $psProfile) -or
        -not (Select-String -Path $psProfile -Pattern 'starship init' -Quiet)) {
        Add-Content -Path $psProfile -Value "`n$starshipInit"
    }
}

$bwStatus = bw status 2>$null | ConvertFrom-Json
if ($bwStatus.status -eq 'unauthenticated') {
    bw login
    if ($LASTEXITCODE -ne 0) { throw 'Bitwarden login failed.' }
    $bwStatus = bw status | ConvertFrom-Json
}
if ($bwStatus.status -eq 'locked') {
    $env:BW_SESSION = bw unlock --raw
    if ($LASTEXITCODE -ne 0) { throw 'Bitwarden unlock failed.' }
}

$sshDir = "$env:USERPROFILE\.ssh"
if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir | Out-Null
}
$pubKey = ssh-add -L 2>$null | Select-String 'alexwaibelmsft'
if ($pubKey) {
    $pubKey.Line | Out-File -Encoding utf8 -FilePath "$sshDir\alexwaibelmsft.pub"
} else {
    Write-Warning 'Could not find alexwaibelmsft key in the Bitwarden SSH agent.'
}

git -C "$env:USERPROFILE\.local\share\chezmoi" remote set-url origin `
    git@github.com:alexwaibel/dotfiles-work.git

$wtSettings = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
if (Test-Path $wtSettings) {
    $gruvboxScheme = @{
        name = 'Gruvbox Dark'
        background = '#282828'
        foreground = '#EBDBB2'
        cursorColor = '#EBDBB2'
        selectionBackground = '#504945'
        black = '#282828'
        red = '#CC241D'
        green = '#98971A'
        yellow = '#D79921'
        blue = '#458588'
        purple = '#B16286'
        cyan = '#689D6A'
        white = '#A89984'
        brightBlack = '#928374'
        brightRed = '#FB4934'
        brightGreen = '#B8BB26'
        brightYellow = '#FABD2F'
        brightBlue = '#83A598'
        brightPurple = '#D3869B'
        brightCyan = '#8EC07C'
        brightWhite = '#EBDBB2'
    }
    $gruvboxTheme = [PSCustomObject]@{
        name = 'Gruvbox Dark'
        tab = [PSCustomObject]@{
            background = '#3C3836'
            unfocusedBackground = '#1D2021'
        }
        tabRow = [PSCustomObject]@{ background = '#1D2021' }
        window = [PSCustomObject]@{ applicationTheme = 'dark' }
    }
    $wt = Get-Content $wtSettings -Raw | ConvertFrom-Json
    if (-not ($wt.schemes | Where-Object { $_.name -eq 'Gruvbox Dark' })) {
        $wt.schemes += [PSCustomObject]$gruvboxScheme
    }
    if (-not $wt.profiles.defaults) {
        $wt.profiles | Add-Member defaults ([PSCustomObject]@{}) -Force
    }
    $wt.profiles.defaults | Add-Member colorScheme 'Gruvbox Dark' -Force
    if (-not $wt.themes) {
        $wt | Add-Member themes @() -Force
    }
    if (-not ($wt.themes | Where-Object { $_.name -eq 'Gruvbox Dark' })) {
        $wt.themes += $gruvboxTheme
    }
    $wt | Add-Member theme 'Gruvbox Dark' -Force
    $wt | ConvertTo-Json -Depth 100 | Set-Content $wtSettings -Encoding utf8
}

$themePath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
Set-ItemProperty -Path $themePath -Name AppsUseLightTheme -Value 0
Set-ItemProperty -Path $themePath -Name SystemUsesLightTheme -Value 0

$explorerPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-ItemProperty -Path $explorerPath -Name Hidden -Value 1
Set-ItemProperty -Path $explorerPath -Name HideFileExt -Value 0

Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' `
    -Name SearchboxTaskbarMode -Value 0

$shell = New-Object -ComObject Shell.Application
$shell.Namespace($env:USERPROFILE).Self.InvokeVerb('pintohome')

Write-Host 'Windows user configuration ready.'
