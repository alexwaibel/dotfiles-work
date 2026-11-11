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
  jq -e 'has("hostWorktree") or has("importedCommit") or has("exportedCommit") or has("syncedCommit")' \
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
    'has("hostWorktree") or has("importedCommit") or has("exportedCommit") or has("syncedCommit")' \
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
      importedCommit,
      importedRef,
      integratedCommit,
      pendingIntegration,
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
