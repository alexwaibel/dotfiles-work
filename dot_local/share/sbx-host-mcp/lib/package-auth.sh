# shellcheck shell=bash

ado_organization() {
  local repo_path="$1"
  if [[ -n "${SBX_WORK_ADO_ORGANIZATION:-}" ]]; then
    [[ "$SBX_WORK_ADO_ORGANIZATION" =~ ^[A-Za-z0-9._-]+$ ]] ||
      die "invalid SBX_WORK_ADO_ORGANIZATION"
    printf '%s\n' "$SBX_WORK_ADO_ORGANIZATION"
    return
  fi
  local remote
  remote="$(git -C "$repo_path" remote get-url origin)"
  if [[ "$remote" =~ ^https://([^.]+)\.visualstudio\.com/ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$remote" =~ ^https://dev\.azure\.com/([^/]+)/ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    die "cannot derive Azure DevOps organization from origin: $remote"
  fi
}

package_read_token() {
  local organization="$1" id="$2"
  local powershell_bin="${SBX_WORK_POWERSHELL_BIN:-powershell.exe}"
  [[ "$organization" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "invalid Azure DevOps organization: $organization"
  command -v "$powershell_bin" >/dev/null 2>&1 ||
    die "powershell.exe is required for Windows-host Azure authentication"
  "$powershell_bin" -NoProfile -Command \
    "azureauth ado pat --organization '$organization' --display-name 'DockerSandbox-wi-$id' --scope vso.packaging --output token --prompt-hint 'DockerSandbox-wi-$id' --timeout 30" |
    tr -d '\r'
}
