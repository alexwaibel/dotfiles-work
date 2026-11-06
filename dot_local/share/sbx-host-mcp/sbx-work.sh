#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq filters intentionally use single quotes.

set -euo pipefail

readonly PROGRAM="${0##*/}"
readonly DEFAULT_REPOS_ROOT="${HOME}/repos"
readonly DEFAULT_STATE_ROOT="${XDG_STATE_HOME:-${HOME}/.local/state}/sbx-work"

repos_root="${SBX_WORK_REPOS_ROOT:-$DEFAULT_REPOS_ROOT}"
state_root="${SBX_WORK_STATE_ROOT:-$DEFAULT_STATE_ROOT}"
tasks_root="${SBX_WORK_TASKS_ROOT:-${state_root}/tasks}"
dry_run=false

usage() {
  cat <<'EOF'
Usage:
  sbx-work inspect WORK_ITEM
  sbx-work [--dry-run] seed WORK_ITEM SLUG [REPO]
  sbx-work dispatch WORK_ITEM TASK_ID
  sbx-work [--dry-run] export WORK_ITEM
  sbx-work [--dry-run] sync WORK_ITEM

Commands:
  inspect   Report transfer metadata and whether its sandbox still exists.
  seed      Create a native clone-mode sandbox, create the task branch, and
            restore detected Azure Artifacts dependencies before agent startup.
  dispatch  Run one noninteractive Copilot task in the existing sandbox.
  export    Bundle committed VM work into a standard host worktree and rebase.
  sync      Transfer the rebased host branch back into the VM.

Use native sbx commands for everything else:
  sbx run --name wi-<id>-vm
  sbx ls
  sbx policy allow network --sandbox wi-<id>-vm <rule>
  sbx stop wi-<id>-vm
  sbx rm wi-<id>-vm

REPO defaults to the current Git repository name. Postinstall, rebuild, setup,
test, and validation commands remain the coding agent's responsibility.
EOF
}

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

uses_azure_artifacts() {
  local repo_path="$1"
  local config
  for config in "$repo_path/.npmrc" "$repo_path/.yarnrc.yml"; do
    [[ -f "$config" ]] || continue
    grep -Eq 'pkgs\.(dev\.azure\.com|visualstudio\.com)' "$config" && return 0
  done
  return 1
}

detect_install_command() {
  local repo_path="$1"
  [[ -f "$repo_path/package.json" ]] || return 1
  local declared
  declared="$(jq -r '.packageManager // empty' "$repo_path/package.json")"

  case "$declared" in
    yarn@*)
      local yarn_version="${declared#yarn@}"
      local yarn_major="${yarn_version%%.*}"
      if [[ "$yarn_major" =~ ^[0-9]+$ ]] && ((yarn_major >= 2)); then
        printf 'yarn\0install\0--immutable\0'
      else
        printf 'yarn\0install\0--frozen-lockfile\0'
      fi
      ;;
    pnpm@*)
      printf 'pnpm\0install\0--frozen-lockfile\0'
      ;;
    npm@*)
      [[ -f "$repo_path/package-lock.json" ]] || return 1
      printf 'npm\0ci\0'
      ;;
    *)
      return 1
      ;;
  esac
}

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
    return
  fi
  if [[ "$remote" =~ ^https://dev\.azure\.com/([^/]+)/ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi
  die "cannot derive Azure DevOps organization from origin: $remote"
}

windows_ado_pat() {
  local organization="$1"
  local id="$2"
  local powershell_bin="${SBX_WORK_POWERSHELL_BIN:-powershell.exe}"
  [[ "$organization" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "invalid Azure DevOps organization: $organization"
  command -v "$powershell_bin" >/dev/null 2>&1 ||
    die "powershell.exe is required for Windows-host Azure authentication"

  "$powershell_bin" -NoProfile -Command \
    "azureauth ado pat --organization '$organization' --display-name 'DockerSandbox-wi-$id' --scope vso.packaging --output token --prompt-hint 'DockerSandbox-wi-$id' --timeout 30" |
    tr -d '\r'
}

seed() {
  local id="$1"
  local slug="$2"
  local repo
  repo="$(resolve_repo "${3:-}")"
  validate_work_item "$id"
  validate_slug "$slug"

  local repo_path sbx base_branch sandbox branch repo_dir git_name git_email
  repo_path="$(canonical_repo "$repo")"
  sbx="$(find_sbx)"
  base_branch="$(discover_base_branch "$repo_path")"
  sandbox="wi-${id}-vm"
  branch="users/alwaibel/agent/${id}-${slug}"
  repo_dir=""
  git_name="$(git -C "$repo_path" config user.name)"
  git_email="$(git -C "$repo_path" config user.email)"
  [[ -n "$git_name" && -n "$git_email" ]] ||
    die "canonical repository must resolve git user.name and user.email"

  if ! $dry_run; then
    clear_stale_state "$id" "$sbx" "$sandbox"
    sandbox_exists "$sbx" "$sandbox" &&
      die "sandbox already exists without metadata: $sandbox"
  else
    [[ ! -e "$(state_file "$id")" ]] ||
      die "metadata already exists: $(state_file "$id")"
  fi

  ensure_canonical_ready "$repo_path" "$base_branch"
  if [[ "$sbx" == *.exe ]]; then
    ensure_windows_safe_directory "$repo_path"
  fi
  git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch" &&
    die "local branch already exists: $branch"
  git -C "$repo_path" show-ref --verify --quiet "refs/remotes/origin/$branch" &&
    die "remote branch already exists: $branch"

  note "refreshing ${repo}/${base_branch}"
  run git -C "$repo_path" fetch origin
  run git -C "$repo_path" merge --ff-only "origin/$base_branch"
  local base_sha
  base_sha="$(git -C "$repo_path" rev-parse "$base_branch")"

  local -a install_command=()
  if uses_azure_artifacts "$repo_path"; then
    mapfile -d '' -t install_command < <(detect_install_command "$repo_path")
    ((${#install_command[@]} > 0)) ||
      die "Azure Artifacts is configured but package.json has no supported packageManager"
  fi

  local seed_started=false
  cleanup_incomplete_seed() {
    if $seed_started && ! $dry_run; then
      note "cleaning incomplete sandbox $sandbox"
      sbx_call "$sbx" rm --force "$sandbox" >/dev/null 2>&1 || true
      rm -f "$(state_file "$id")"
    fi
  }
  seed_step() {
    local exit_code
    "$@" && return 0
    exit_code=$?
    cleanup_incomplete_seed
    return "$exit_code"
  }

  note "creating mountless sandbox $sandbox"
  seed_started=true
  seed_step run sbx_call "$sbx" create \
    --clone \
    --name "$sandbox" \
    --static-mcp none \
    --skills off \
    copilot \
    "$(win_path "$repo_path")"
  seed_step run sbx_call "$sbx" run -d --name "$sandbox"
  if $dry_run; then
    run sbx_call "$sbx" exec "$sandbox" -- pwd
    repo_dir="/workspace/${repo}"
  else
    local pwd_exit
    set +e
    repo_dir="$(sbx_call "$sbx" exec "$sandbox" -- pwd)"
    pwd_exit=$?
    set -e
    if [[ "$pwd_exit" -ne 0 ]]; then
      cleanup_incomplete_seed
      return "$pwd_exit"
    fi
  fi
  [[ "$repo_dir" == /* ]] || {
    cleanup_incomplete_seed
    die "sandbox clone returned an invalid workspace path"
  }
  seed_step sbx_exec_shell "$sbx" "$sandbox" \
    "git -C $(printf '%q' "$repo_dir") checkout -b $(printf '%q' "$branch") && git -C $(printf '%q' "$repo_dir") config user.name $(printf '%q' "$git_name") && git -C $(printf '%q' "$repo_dir") config user.email $(printf '%q' "$git_email")"
  seed_step sbx_exec_shell "$sbx" "$sandbox" \
    'if command -v corepack >/dev/null 2>&1; then
       mkdir -p "$HOME/.local/bin"
       corepack enable --install-directory "$HOME/.local/bin" || echo "warning: corepack shims unavailable" >&2
       rm -f "$HOME/.local/bin/yarn"
       cat >"$HOME/.local/bin/yarn" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
dir="$PWD"
while [[ "$dir" != / ]]; do
  yarn_path="$(sed -n "s/^yarnPath:[[:space:]]*//p" "$dir/.yarnrc.yml" 2>/dev/null | head -n1)"
  yarn_path="${yarn_path#\"}"
  yarn_path="${yarn_path%\"}"
  if [[ -n "$yarn_path" ]]; then
    [[ "$yarn_path" = /* ]] || yarn_path="$dir/$yarn_path"
    [[ -f "$yarn_path" ]] && exec node "$yarn_path" "$@"
  fi
  dir="${dir%/*}"
  [[ -n "$dir" ]] || dir=/
done
exec corepack yarn "$@"
EOF
       chmod u+x "$HOME/.local/bin/yarn"
     fi'

  if ((${#install_command[@]} > 0)); then
    seed_step run sbx_call "$sbx" policy allow network --sandbox "$sandbox" \
      '**.vsassets.io'
    note "restoring private dependencies before agent startup"
    seed_step restore_private_dependencies \
      "$id" "$sbx" "$sandbox" "$repo_dir" "$repo_path" \
      "${install_command[@]}"
  fi

  if ! $dry_run; then
    seed_step write_state "$id" \
      --arg id "$id" \
      --arg slug "$slug" \
      --arg repo "$repo" \
      --arg sandbox "$sandbox" \
      --arg branch "$branch" \
      --arg baseBranch "$base_branch" \
      --arg baseSha "$base_sha" \
      --arg repoDir "$repo_dir" \
      --arg transferMode "clone" \
      '{
        workItem: $id,
        slug: $slug,
        repo: $repo,
        sandbox: $sandbox,
        branch: $branch,
        baseBranch: $baseBranch,
        baseSha: $baseSha,
        repoDir: $repoDir,
        transferMode: $transferMode
      }'
  fi
  seed_started=false

  note "seeded $sandbox"
  printf 'Repository: %s\n' "$repo_dir"
}

readonly PACKAGE_RUNNER='
cd "$1"
shift
export PATH="$HOME/.local/bin:$PATH"
exec "$@"
'

restore_private_dependencies() {
  local id="$1"
  local sbx="$2"
  local sandbox="$3"
  local repo_dir="$4"
  local repo_path="$5"
  shift 5
  local executable="${1##*/}"
  local -a install_command=("$@")
  case "$executable" in
    yarn) ;;
    npm | pnpm)
      install_command+=("--ignore-scripts")
      ;;
  esac

  local organization
  organization="$(ado_organization "$repo_path")"

  if $dry_run; then
    printf '+ ADO_NPM_TOKEN=<redacted> '
    quote_command "$sbx" exec --no-input \
      -e ADO_NPM_TOKEN \
      -e YARN_ENABLE_SCRIPTS=false \
      -e npm_config_ignore_scripts=true \
      -e PNPM_CONFIG_IGNORE_SCRIPTS=true \
      "$sandbox" -- \
      bash -lc "$PACKAGE_RUNNER" bash "$repo_dir" "${install_command[@]}"
    printf '\n'
    return
  fi

  local token
  token="$(windows_ado_pat "$organization" "$id")"
  [[ -n "$token" ]] || die "Windows Azure authentication returned an empty token"
  [[ "$token" != *$'\n'* ]] ||
    die "Windows Azure authentication returned unexpected multi-line output"
  local forwarded_wslenv="${WSLENV:+${WSLENV}:}ADO_NPM_TOKEN"
  WSLENV="$forwarded_wslenv" ADO_NPM_TOKEN="$token" "$sbx" exec --no-input \
    -e ADO_NPM_TOKEN \
    -e YARN_ENABLE_SCRIPTS=false \
    -e npm_config_ignore_scripts=true \
    -e PNPM_CONFIG_IGNORE_SCRIPTS=true \
    "$sandbox" -- \
    bash -lc "$PACKAGE_RUNNER" bash "$repo_dir" "${install_command[@]}"
  unset token ADO_NPM_TOKEN

  case "$executable" in
    yarn)
      sbx_exec_shell "$sbx" "$sandbox" \
        "cd $(printf '%q' "$repo_dir") && { test -f node_modules/.yarn-state.yml || test -f .pnp.cjs || test -f .yarn/install-state.gz; }"
      ;;
    npm)
      sbx_exec_shell "$sbx" "$sandbox" \
        "cd $(printf '%q' "$repo_dir") && test -d node_modules"
      ;;
    pnpm)
      sbx_exec_shell "$sbx" "$sandbox" \
        "cd $(printf '%q' "$repo_dir") && test -d node_modules/.pnpm"
      ;;
  esac
}

dispatch_task() {
  local id="$1"
  local task_id="$2"
  validate_work_item "$id"
  validate_task_id "$task_id"

  local prompt_file log_file metadata_file
  prompt_file="$(task_prompt_file "$task_id")"
  log_file="$(task_log_file "$task_id")"
  metadata_file="$(task_file "$task_id")"
  [[ -f "$prompt_file" && -f "$metadata_file" ]] ||
    die "task files are incomplete: $task_id"

  mkdir -p "$tasks_root"
  exec 8>"${state_root}/task-${id}.lock"
  if ! flock -n 8; then
    update_task "$task_id" \
      '.status = "failed" | .error = "another task is active for this work item"'
    die "another task is active for work item $id"
  fi

  local sbx sandbox repo_dir exit_code status
  sbx="$(find_sbx)"
  sandbox="$(state_value "$id" '.sandbox')"
  repo_dir="$(state_value "$id" '.repoDir')"
  update_task "$task_id" \
    'if .cancelRequested or .status == "canceled" then
       .status = "canceled"
     else
       .status = "running" | .runnerPid = $pid | .startedAt = $started
     end' \
    --argjson pid "$$" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$(jq -r '.status' "$metadata_file")" == "canceled" ]]; then
    rm -f "$prompt_file"
    return 130
  fi

  set +e
  sbx_call "$sbx" exec -i -w "$repo_dir" "$sandbox" -- \
    bash -lc 'prompt="$(cat)"; export PATH="$HOME/.local/bin:$PATH"; exec copilot --yolo -p "$prompt"' \
    <"$prompt_file" >"$log_file" 2>&1
  exit_code=$?
  set -e

  status="failed"
  [[ "$exit_code" -eq 0 ]] && status="completed"
  update_task "$task_id" \
    'if .status == "canceled" or .cancelRequested then
       .status = "canceled" | .completedAt = $completed
     else
       .status = $status |
       .exitCode = $exitCode |
       .completedAt = $completed
     end' \
    --arg status "$status" \
    --argjson exitCode "$exit_code" \
    --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rm -f "$prompt_file"
  return "$exit_code"
}

export_work() {
  local id="$1"
  validate_work_item "$id"
  local sbx sandbox repo branch base_branch base_sha repo_dir slug repo_path transfer_mode
  sbx="$(find_sbx)"
  sandbox="$(state_value "$id" '.sandbox')"
  repo="$(state_value "$id" '.repo')"
  branch="$(state_value "$id" '.branch')"
  base_branch="$(state_value "$id" '.baseBranch')"
  base_sha="$(state_value "$id" '.baseSha')"
  repo_dir="$(state_value "$id" '.repoDir')"
  slug="$(state_value "$id" '.slug')"
  transfer_mode="$(state_value "$id" '.transferMode // "bundle"')"
  repo_path="$(canonical_repo "$repo")"

  local vm_status
  vm_status="$(sbx_call "$sbx" exec "$sandbox" -- git -C "$repo_dir" status --porcelain)"
  [[ -z "$vm_status" ]] || die "sandbox repository has uncommitted changes"

  local vm_head
  vm_head="$(sbx_call "$sbx" exec "$sandbox" -- git -C "$repo_dir" rev-parse HEAD)"
  [[ "$vm_head" != "$base_sha" ]] || die "sandbox branch has no commits to export"

  local export_ref="refs/remotes/sbx-work/${id}"
  local host_bundle=""
  if [[ "$transfer_mode" == "clone" ]]; then
    local sandbox_remote="sandbox-${sandbox}"
    run windows_git "$repo_path" fetch \
      "$sandbox_remote" "+$branch:$export_ref"
  else
    local vm_bundle="/tmp/sbx-work-${id}.bundle"
    host_bundle="${state_root}/${id}-export.bundle"
    sbx_exec_shell "$sbx" "$sandbox" \
      "cd $(printf '%q' "$repo_dir") && git bundle create $(printf '%q' "$vm_bundle") $(printf '%q' "$branch") ^$(printf '%q' "$base_sha") && git bundle verify $(printf '%q' "$vm_bundle")"
    run sbx_call "$sbx" cp "$sandbox:$vm_bundle" "$(win_path "$host_bundle")"
    run git -C "$repo_path" bundle verify "$host_bundle"
  fi
  run git -C "$repo_path" fetch origin

  local worktree="${repos_root}/worktrees/${repo}/${id}-${slug}"
  if [[ ! -d "$worktree" ]]; then
    if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then
      run git -C "$repo_path" worktree add "$worktree" "$branch"
    else
      run git -C "$repo_path" worktree add "$worktree" -b "$branch" "$base_sha"
    fi
  fi

  [[ -z "$(git -C "$worktree" status --porcelain)" ]] ||
    die "host worktree has uncommitted changes"
  [[ "$(git -C "$worktree" branch --show-current)" == "$branch" ]] ||
    die "host worktree is not on the expected branch"

  if [[ "$transfer_mode" != "clone" ]]; then
    run git -C "$worktree" fetch "$host_bundle" "+$branch:$export_ref"
  fi
  [[ "$(git -C "$worktree" rev-parse "$export_ref")" == "$vm_head" ]] ||
    die "imported branch does not match sandbox HEAD"
  local original_base original_patch_id
  original_base="$(git -C "$worktree" merge-base "origin/$base_branch" "$export_ref")"
  original_patch_id="$(
    git -C "$worktree" diff "$original_base" "$export_ref" |
      git patch-id --stable |
      awk '{print $1}'
  )"
  [[ -n "$original_patch_id" ]] || die "exported branch has no patch to verify"
  if git -C "$worktree" merge-base --is-ancestor HEAD "$export_ref"; then
    run git -C "$worktree" merge --ff-only "$export_ref"
  else
    local previous_exported host_base host_patch_id
    previous_exported="$(read_state "$id" | jq -r '.exportedCommit // empty')"
    [[ -n "$previous_exported" && "$(git -C "$worktree" rev-parse HEAD)" == "$previous_exported" ]] ||
      die "host branch changed since the last recorded export; preserve both branches for review"
    host_base="$(git -C "$worktree" merge-base "origin/$base_branch" HEAD)"
    host_patch_id="$(
      git -C "$worktree" diff "$host_base" HEAD |
        git patch-id --stable |
        awk '{print $1}'
    )"
    [[ "$host_patch_id" == "$original_patch_id" ]] ||
      die "host branch diverged from the VM patch; preserve both branches for review"
    note "host branch already contains the equivalent rebased VM patch"
  fi
  run git -C "$worktree" rebase "origin/$base_branch"
  local exported_commit
  exported_commit="$(git -C "$worktree" rev-parse HEAD)"
  local rebased_patch_id
  rebased_patch_id="$(
    git -C "$worktree" diff "origin/$base_branch" "$exported_commit" |
      git patch-id --stable |
      awk '{print $1}'
  )"
  [[ "$rebased_patch_id" == "$original_patch_id" ]] ||
    die "rebased export changed the VM patch"
  [[ -z "$host_bundle" ]] || run rm -f "$host_bundle"

  if ! $dry_run; then
    update_state "$id" \
      '.hostWorktree = $worktree |
       .exportedCommit = $commit |
       .patchPreserved = true' \
      --arg worktree "$worktree" \
      --arg commit "$exported_commit"
  fi
  note "exported to $worktree at $exported_commit; VM patch preserved"
}

sync_work() {
  local id="$1"
  validate_work_item "$id"
  local sbx sandbox branch base_sha repo_dir worktree
  sbx="$(find_sbx)"
  sandbox="$(state_value "$id" '.sandbox')"
  branch="$(state_value "$id" '.branch')"
  base_sha="$(state_value "$id" '.baseSha')"
  repo_dir="$(state_value "$id" '.repoDir')"
  worktree="$(state_value "$id" '.hostWorktree')"

  [[ -z "$(git -C "$worktree" status --porcelain)" ]] ||
    die "host worktree has uncommitted changes"
  [[ -z "$(sbx_call "$sbx" exec "$sandbox" -- git -C "$repo_dir" status --porcelain)" ]] ||
    die "sandbox repository has uncommitted changes"

  local bundle="${state_root}/${id}-sync.bundle"
  run git -C "$worktree" bundle create "$bundle" "$branch" "^$base_sha"
  run git -C "$worktree" bundle verify "$bundle"
  run sbx_call "$sbx" cp "$(win_path "$bundle")" "$sandbox:/tmp/sbx-work-${id}-sync.bundle"
  sbx_exec_shell "$sbx" "$sandbox" \
    "cd $(printf '%q' "$repo_dir") && git fetch /tmp/sbx-work-${id}-sync.bundle $(printf '%q' "$branch"):refs/remotes/host/rebased && git reset --hard refs/remotes/host/rebased"
  run rm -f "$bundle"

  local synced_commit
  synced_commit="$(git -C "$worktree" rev-parse HEAD)"
  if ! $dry_run; then
    update_state "$id" '.syncedCommit = $commit' --arg commit "$synced_commit"
  fi
  note "synced $synced_commit; run repository validation inside the VM"
}

while (($#)); do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

command_name="${1:-}"
[[ -n "$command_name" ]] || {
  usage
  exit 2
}
shift

case "$command_name" in
  inspect)
    (($# == 1)) || die "inspect requires WORK_ITEM"
    acquire_lock
    inspect_work "$1"
    ;;
  seed)
    (($# >= 2 && $# <= 3)) || die "seed requires WORK_ITEM SLUG [REPO]"
    acquire_lock
    seed "$@"
    ;;
  dispatch)
    (($# == 2)) || die "dispatch requires WORK_ITEM TASK_ID"
    dispatch_task "$1" "$2"
    ;;
  export)
    (($# == 1)) || die "export requires WORK_ITEM"
    acquire_lock
    export_work "$1"
    ;;
  sync)
    (($# == 1)) || die "sync requires WORK_ITEM"
    acquire_lock
    sync_work "$1"
    ;;
  *)
    die "unknown command: $command_name"
    ;;
esac
