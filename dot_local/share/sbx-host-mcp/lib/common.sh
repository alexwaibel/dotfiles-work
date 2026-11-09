# shellcheck shell=bash
# shellcheck disable=SC2154

die() {
  printf '%s: %s\n' "$PROGRAM" "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

quote_command() {
  printf '%q ' "$@"
}

run() {
  if $dry_run; then
    printf '+ '
    quote_command "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

acquire_lock() {
  mkdir -p "$state_root"
  exec 9>"${state_root}/operation.lock"
  flock -n 9 ||
    die "another sbx-work operation is already running"
}

find_sbx() {
  if [[ -n "${SBX_WORK_SBX_BIN:-}" ]]; then
    printf '%s\n' "$SBX_WORK_SBX_BIN"
    return
  fi
  if command -v sbx.exe >/dev/null 2>&1; then
    command -v sbx.exe
    return
  fi
  local windows_sbx="/mnt/c/Users/${USER}/AppData/Local/DockerSandboxes/bin/sbx.exe"
  [[ -x "$windows_sbx" ]] || die "sbx.exe not found; set SBX_WORK_SBX_BIN"
  printf '%s\n' "$windows_sbx"
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

windows_git_command() {
  local git_bin="${SBX_WORK_WINDOWS_GIT_BIN:-git.exe}"
  local shim_dir="/mnt/c/Users/${USER}/AppData/Local/DockerSandboxes/compat"
  if [[ "$git_bin" == *.exe && -x "$shim_dir/git.exe" ]]; then
    PATH="$shim_dir:$PATH" "$git_bin" "$@"
  else
    "$git_bin" "$@"
  fi
}

windows_git() {
  local repo_path="$1"
  shift
  if [[ "${SBX_WORK_WINDOWS_GIT_BIN:-git.exe}" == *.exe ]]; then
    windows_git_command -C "$(win_path "$repo_path")" "$@"
  else
    windows_git_command -C "$repo_path" "$@"
  fi
}

ensure_windows_safe_directory() {
  local repo_path="$1"
  local safe_directory
  safe_directory="%(prefix)/$(wslpath -m "$repo_path")"
  if ! windows_git_command config --global --fixed-value --get-all \
    safe.directory "$safe_directory" >/dev/null 2>&1; then
    windows_git_command config --global --add safe.directory "$safe_directory"
  fi
}

sandbox_exists() {
  local sbx="$1"
  local sandbox="$2"
  sbx_call "$sbx" ls -q | tr -d '\r' | grep -Fxq "$sandbox"
}

clear_stale_state() {
  local id="$1"
  local sbx="$2"
  local sandbox="$3"
  local file
  file="$(state_file "$id")"
  [[ -f "$file" ]] || return 0

  local recorded_sandbox
  recorded_sandbox="$(jq -er '.sandbox' "$file")"
  [[ "$recorded_sandbox" == "$sandbox" ]] ||
    die "metadata sandbox mismatch for work item $id"
  sandbox_exists "$sbx" "$sandbox" &&
    die "metadata and sandbox already exist for work item $id"
  jq -e 'has("hostWorktree") or has("exportedCommit") or has("syncedCommit")' \
    "$file" >/dev/null &&
    die "stale metadata has exported host work; remove it manually after review: $file"

  note "removing stale unexported metadata for absent sandbox $sandbox"
  rm -f "$file"
}

inspect_work() {
  local id="$1"
  validate_work_item "$id"
  local file sandbox sandbox_status
  file="$(state_file "$id")"
  [[ -f "$file" ]] || die "metadata not found for work item $id"
  sandbox="$(jq -er '.sandbox' "$file")"

  if sandbox_exists "$(find_sbx)" "$sandbox"; then
    sandbox_status="present"
  elif jq -e \
    'has("hostWorktree") or has("exportedCommit") or has("syncedCommit")' \
    "$file" >/dev/null; then
    sandbox_status="missing-exported"
  else
    sandbox_status="missing-unexported"
  fi

  jq --arg sandboxStatus "$sandbox_status" \
    '({
      workItem,
      slug,
      repo,
      sandbox,
      branch,
      baseBranch,
      baseSha,
      repoDir,
      hostWorktree,
      exportedCommit,
      syncedCommit,
      patchPreserved
    } | with_entries(select(.value != null))) + {
      sandboxStatus: $sandboxStatus
    }' "$file"
}

validate_work_item() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "work item must be a positive integer"
}

validate_slug() {
  [[ "$1" =~ ^[a-z0-9]+([a-z0-9-]*[a-z0-9])?$ ]] ||
    die "slug must contain lowercase letters, digits, and internal hyphens"
}

resolve_repo() {
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' "$1"
    return
  fi
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "REPO is required outside a Git repository"
  basename "$top"
}

canonical_repo() {
  local path="${repos_root}/$1"
  [[ -d "$path/.git" ]] || die "canonical clone not found: $path"
  printf '%s\n' "$path"
}

discover_base_branch() {
  local repo_path="$1"
  local origin_head
  origin_head="$(
    git -C "$repo_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null ||
      true
  )"
  if [[ -n "$origin_head" ]]; then
    printf '%s\n' "${origin_head#origin/}"
    return
  fi
  if git -C "$repo_path" show-ref --verify --quiet refs/remotes/origin/main; then
    printf 'main\n'
    return
  fi
  if git -C "$repo_path" show-ref --verify --quiet refs/remotes/origin/master; then
    printf 'master\n'
    return
  fi
  die "cannot discover the default branch from origin/HEAD, origin/main, or origin/master"
}

ensure_canonical_ready() {
  local repo_path="$1"
  local base_branch="$2"
  local current_branch
  current_branch="$(git -C "$repo_path" branch --show-current)"
  [[ "$current_branch" == "$base_branch" ]] ||
    die "canonical clone must be on $base_branch, found $current_branch"
  [[ -z "$(git -C "$repo_path" status --porcelain)" ]] ||
    die "canonical clone has local changes: $repo_path"
}

state_file() {
  printf '%s/%s.json\n' "$state_root" "$1"
}

validate_task_id() {
  [[ "$1" =~ ^task-[a-f0-9-]{36}$ ]] ||
    die "invalid task ID"
}

task_file() {
  printf '%s/%s.json\n' "$tasks_root" "$1"
}

task_log_file() {
  printf '%s/%s.log\n' "$tasks_root" "$1"
}

task_prompt_file() {
  printf '%s/%s.prompt\n' "$tasks_root" "$1"
}

update_task() {
  local task_id="$1"
  local filter="$2"
  shift 2
  local file tmp
  file="$(task_file "$task_id")"
  [[ -f "$file" ]] || die "task metadata not found: $task_id"
  tmp="${file}.tmp"
  jq "$@" "$filter" "$file" >"$tmp"
  mv "$tmp" "$file"
}

read_state() {
  local file
  file="$(state_file "$1")"
  [[ -f "$file" ]] || die "metadata not found for work item $1"
  cat "$file"
}

state_value() {
  local id="$1"
  local query="$2"
  read_state "$id" | jq -er "$query"
}

write_state() {
  local id="$1"
  shift
  local file tmp
  file="$(state_file "$id")"
  mkdir -p "$state_root"
  tmp="${file}.tmp"
  jq -n "$@" >"$tmp"
  mv "$tmp" "$file"
}

update_state() {
  local id="$1"
  local filter="$2"
  shift 2
  local file tmp
  file="$(state_file "$id")"
  [[ -f "$file" ]] || die "metadata not found for work item $id"
  tmp="${file}.tmp"
  jq "$@" "$filter" "$file" >"$tmp"
  mv "$tmp" "$file"
}

win_path() {
  wslpath -w "$1"
}

sbx_exec_shell() {
  local sbx="$1"
  local sandbox="$2"
  local command="$3"
  run sbx_call "$sbx" exec "$sandbox" -- bash -lc "$command"
}
