# shellcheck shell=bash
# shellcheck disable=SC2154

find_sbx() {
  if [[ -n "${SBX_WORK_SBX_BIN:-}" ]]; then
    printf '%s\n' "$SBX_WORK_SBX_BIN"
  elif command -v sbx >/dev/null 2>&1; then
    command -v sbx
  elif command -v sbx.exe >/dev/null 2>&1; then
    command -v sbx.exe
  else
    local windows_sbx="/mnt/c/Users/${USER}/AppData/Local/DockerSandboxes/bin/sbx.exe"
    [[ -x "$windows_sbx" ]] || die "sbx not found; set SBX_WORK_SBX_BIN"
    printf '%s\n' "$windows_sbx"
  fi
}

sbx_call() {
  local sbx="$1"
  shift
  local command="$1"
  shift
  local shim_dir="/mnt/c/Users/${USER}/AppData/Local/DockerSandboxes/compat"
  if [[ "$sbx" == *.exe && -x "$shim_dir/git.exe" ]]; then
    WSLENV="${WSLENV:+${WSLENV}:}PATH/lp" PATH="$shim_dir" \
      "$sbx" "$command" --no-input "$@"
  else
    "$sbx" "$command" --no-input "$@"
  fi
}

sbx_host_path() {
  if [[ "$1" == *.exe ]]; then
    wslpath -w "$2"
  else
    printf '%s\n' "$2"
  fi
}

sbx_copy_to() {
  sbx_call "$1" cp "$(sbx_host_path "$1" "$3")" "$2:$4"
}

sbx_copy_from() {
  sbx_call "$1" cp "$2:$3" "$(sbx_host_path "$1" "$4")"
}

sbx_with_env() {
  local sbx="$1" forwarded="${WSLENV:-}"
  shift
  while [[ "${1:-}" != -- ]]; do
    [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
      die "invalid environment variable for sbx"
    if [[ "$sbx" == *.exe ]]; then
      forwarded="${forwarded:+${forwarded}:}$1"
    fi
    shift
  done
  shift
  WSLENV="$forwarded" sbx_call "$sbx" "$@"
}

sbx_prepare_clone() {
  local sbx="$1" repo_path="$2"
  [[ "$sbx" == *.exe ]] || return 0
  local safe_directory git_bin="${SBX_WORK_WINDOWS_GIT_BIN:-git.exe}"
  local shim_dir="/mnt/c/Users/${USER}/AppData/Local/DockerSandboxes/compat"
  safe_directory="%(prefix)/$(wslpath -m "$repo_path")"
  # Native clone still invokes Windows Git; retain its existing compatibility setup.
  if [[ "$git_bin" == *.exe && -x "$shim_dir/git.exe" ]]; then
    local PATH="$shim_dir:$PATH"
  fi
  if ! "$git_bin" config --global --fixed-value --get-all \
    safe.directory "$safe_directory" >/dev/null 2>&1; then
    "$git_bin" config --global --add safe.directory "$safe_directory"
  fi
}

sbx_exec_shell() {
  run sbx_call "$1" exec "$2" -- bash -lc "$3"
}
