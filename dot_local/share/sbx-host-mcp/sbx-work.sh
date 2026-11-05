#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq filters intentionally use single quotes.

set -euo pipefail

readonly PROGRAM="${0##*/}"
readonly DEFAULT_REPOS_ROOT="${HOME}/repos"
readonly DEFAULT_STATE_ROOT="${XDG_STATE_HOME:-${HOME}/.local/state}/sbx-work"

repos_root="${SBX_WORK_REPOS_ROOT:-$DEFAULT_REPOS_ROOT}"
state_root="${SBX_WORK_STATE_ROOT:-$DEFAULT_STATE_ROOT}"
dry_run=false

usage() {
  cat <<'EOF'
Usage:
  sbx-work [--dry-run] seed WORK_ITEM SLUG [REPO]
  sbx-work [--dry-run] ado-install WORK_ITEM -- PACKAGE_MANAGER [ARG...]
  sbx-work [--dry-run] export WORK_ITEM
  sbx-work [--dry-run] sync WORK_ITEM

Commands:
  seed      Work around broken WSL clone mode by seeding a mountless sandbox
            from a verified Git bundle and creating the task branch.
  ado-install
            Run a package install with a process-scoped Azure Artifacts token
            and package lifecycle scripts disabled.
  export    Bundle committed VM work into a standard host worktree and rebase.
  sync      Transfer the rebased host branch back into the VM.

Use native sbx commands for everything else:
  sbx run --name wi-<id>-vm
  sbx ls
  sbx policy allow network --sandbox wi-<id>-vm <rule>
  sbx stop wi-<id>-vm
  sbx rm wi-<id>-vm

REPO defaults to the current Git repository name. Repository setup, test, and
validation commands remain the coding agent's responsibility.
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
  run "$sbx" exec "$sandbox" -- bash -lc "$command"
}

ado_organization() {
  local repo_path="$1"
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

seed() {
  local id="$1"
  local slug="$2"
  local repo
  repo="$(resolve_repo "${3:-}")"
  validate_work_item "$id"
  validate_slug "$slug"

  local metadata
  metadata="$(state_file "$id")"
  [[ ! -e "$metadata" ]] || die "metadata already exists: $metadata"

  local repo_path sbx base_branch sandbox branch repo_dir
  repo_path="$(canonical_repo "$repo")"
  sbx="$(find_sbx)"
  base_branch="$(discover_base_branch "$repo_path")"
  sandbox="wi-${id}-vm"
  branch="users/alwaibel/agent/${id}-${slug}"
  repo_dir="/home/agent/workspace/${repo}"

  ensure_canonical_ready "$repo_path" "$base_branch"
  git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch" &&
    die "local branch already exists: $branch"
  git -C "$repo_path" show-ref --verify --quiet "refs/remotes/origin/$branch" &&
    die "remote branch already exists: $branch"

  note "refreshing ${repo}/${base_branch}"
  run git -C "$repo_path" fetch origin
  run git -C "$repo_path" merge --ff-only "origin/$base_branch"
  local base_sha
  base_sha="$(git -C "$repo_path" rev-parse "$base_branch")"

  local seed_bundle="${state_root}/${id}-seed.bundle"
  run git -C "$repo_path" bundle create "$seed_bundle" "$base_branch"
  run git -C "$repo_path" bundle verify "$seed_bundle"

  note "creating mountless sandbox $sandbox"
  run "$sbx" create --name "$sandbox" copilot
  run "$sbx" run -d --name "$sandbox"
  run "$sbx" cp "$(win_path "$seed_bundle")" "$sandbox:/tmp/${repo}.bundle"
  sbx_exec_shell "$sbx" "$sandbox" \
    "git clone --branch $(printf '%q' "$base_branch") /tmp/$(printf '%q' "$repo").bundle $(printf '%q' "$repo_dir") && git -C $(printf '%q' "$repo_dir") checkout -b $(printf '%q' "$branch")"
  sbx_exec_shell "$sbx" "$sandbox" \
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
  run rm -f "$seed_bundle"

  if ! $dry_run; then
    write_state "$id" \
      --arg id "$id" \
      --arg slug "$slug" \
      --arg repo "$repo" \
      --arg sandbox "$sandbox" \
      --arg branch "$branch" \
      --arg baseBranch "$base_branch" \
      --arg baseSha "$base_sha" \
      --arg repoDir "$repo_dir" \
      '{
        workItem: $id,
        slug: $slug,
        repo: $repo,
        sandbox: $sandbox,
        branch: $branch,
        baseBranch: $baseBranch,
        baseSha: $baseSha,
        repoDir: $repoDir
      }'
  fi

  note "seeded $sandbox"
  printf 'Attach: sbx run --name %s\n' "$sandbox"
  printf 'Then run: /cwd %s\n' "$repo_dir"
}

validate_install_command() {
  local executable="${1##*/}"
  shift
  case "$executable" in
    yarn)
      if (($# > 0)) && [[ "$1" == "install" ]]; then
        shift
      elif (($# > 0)) && [[ "$1" != -* ]]; then
        die "yarn command must be install or install flags"
      fi
      local yarn_argument
      for yarn_argument in "$@"; do
        case "$yarn_argument" in
          --immutable | --immutable-cache | --refresh-lockfile | --check-cache | \
            --check-resolutions | --inline-builds | --json | --mode=skip-builds)
            ;;
          *)
            die "unsupported yarn install argument: $yarn_argument"
            ;;
        esac
      done
      ;;
    npm | pnpm)
      (($# > 0)) || die "$executable requires install or ci"
      [[ "$1" == "install" || "$1" == "ci" ]] ||
        die "$executable command must be install or ci"
      shift
      local npm_argument
      for npm_argument in "$@"; do
        case "$npm_argument" in
          --ignore-scripts | --no-audit | --no-fund | --prefer-offline | \
            --offline | --frozen-lockfile | --lockfile-only | \
            --package-lock-only | --prod | --production | \
            --omit=dev | --omit=optional | --omit=peer | \
            --include=dev | --include=optional | --include=peer)
            ;;
          *)
            die "unsupported $executable install argument: $npm_argument"
            ;;
        esac
      done
      ;;
    *)
      die "unsupported package manager: $executable"
      ;;
  esac

}

ado_install() {
  local id="$1"
  shift
  [[ "${1:-}" == "--" ]] || die "ado-install requires -- before PACKAGE_MANAGER"
  shift
  (($# > 0)) || die "ado-install requires PACKAGE_MANAGER"
  validate_work_item "$id"
  validate_install_command "$@"
  local executable="${1##*/}"
  local -a install_command=("$@")
  case "$executable" in
    yarn)
      install_command+=("--mode=skip-builds")
      ;;
    npm | pnpm)
      install_command+=("--ignore-scripts")
      ;;
  esac

  local package_runner
  package_runner='
cd "$1"
shift
manager="$1"
shift
case "$manager" in
  yarn)
    yarn_path="$(sed -n "s/^yarnPath:[[:space:]]*//p" .yarnrc.yml 2>/dev/null | head -n1)"
    if [ -n "$yarn_path" ] && [ -f "$yarn_path" ]; then
      exec node "$PWD/$yarn_path" "$@"
    fi
    if command -v yarn >/dev/null 2>&1; then
      exec yarn "$@"
    fi
    exec corepack yarn "$@"
    ;;
  npm|pnpm)
    exec "$manager" "$@"
    ;;
esac
'

  local sbx sandbox repo repo_dir repo_path organization
  sbx="$(find_sbx)"
  sandbox="$(state_value "$id" '.sandbox')"
  repo="$(state_value "$id" '.repo')"
  repo_dir="$(state_value "$id" '.repoDir')"
  repo_path="$(canonical_repo "$repo")"
  organization="$(ado_organization "$repo_path")"

  if $dry_run; then
    printf '+ ADO_NPM_TOKEN=<redacted> '
    quote_command "$sbx" exec \
      -e ADO_NPM_TOKEN \
      -e YARN_ENABLE_SCRIPTS=false \
      -e npm_config_ignore_scripts=true \
      -e PNPM_CONFIG_IGNORE_SCRIPTS=true \
      "$sandbox" -- \
      bash -lc "$package_runner" bash "$repo_dir" "${install_command[@]}"
    printf '\n'
    return
  fi

  local token
  token="$(
    azureauth ado pat \
      --organization "$organization" \
      --display-name "DockerSandbox-wi-${id}" \
      --scope vso.packaging \
      --output token \
      --prompt-hint "DockerSandbox-wi-${id}" \
      --timeout 30
  )"
  ADO_NPM_TOKEN="$token" "$sbx" exec \
    -e ADO_NPM_TOKEN \
    -e YARN_ENABLE_SCRIPTS=false \
    -e npm_config_ignore_scripts=true \
    -e PNPM_CONFIG_IGNORE_SCRIPTS=true \
    "$sandbox" -- \
    bash -lc "$package_runner" bash "$repo_dir" "${install_command[@]}"
  unset token ADO_NPM_TOKEN
}

export_work() {
  local id="$1"
  validate_work_item "$id"
  local sbx sandbox repo branch base_branch base_sha repo_dir slug repo_path
  sbx="$(find_sbx)"
  sandbox="$(state_value "$id" '.sandbox')"
  repo="$(state_value "$id" '.repo')"
  branch="$(state_value "$id" '.branch')"
  base_branch="$(state_value "$id" '.baseBranch')"
  base_sha="$(state_value "$id" '.baseSha')"
  repo_dir="$(state_value "$id" '.repoDir')"
  slug="$(state_value "$id" '.slug')"
  repo_path="$(canonical_repo "$repo")"

  local vm_status
  vm_status="$("$sbx" exec "$sandbox" -- git -C "$repo_dir" status --porcelain)"
  [[ -z "$vm_status" ]] || die "sandbox repository has uncommitted changes"

  local vm_head
  vm_head="$("$sbx" exec "$sandbox" -- git -C "$repo_dir" rev-parse HEAD)"
  [[ "$vm_head" != "$base_sha" ]] || die "sandbox branch has no commits to export"

  local vm_bundle="/tmp/sbx-work-${id}.bundle"
  local host_bundle="${state_root}/${id}-export.bundle"
  sbx_exec_shell "$sbx" "$sandbox" \
    "cd $(printf '%q' "$repo_dir") && git bundle create $(printf '%q' "$vm_bundle") $(printf '%q' "$branch") ^$(printf '%q' "$base_sha") && git bundle verify $(printf '%q' "$vm_bundle")"
  run "$sbx" cp "$sandbox:$vm_bundle" "$(win_path "$host_bundle")"
  run git -C "$repo_path" bundle verify "$host_bundle"
  run git -C "$repo_path" fetch origin

  local worktree="${repos_root}/worktrees/${repo}/${id}-${slug}"
  if [[ ! -d "$worktree" ]]; then
    if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then
      run git -C "$repo_path" worktree add "$worktree" "$branch"
    else
      run git -C "$repo_path" worktree add "$worktree" -b "$branch" "origin/$base_branch"
    fi
  fi

  local export_ref="refs/remotes/sbx-work/${id}"
  run git -C "$worktree" fetch "$host_bundle" "$branch:$export_ref"
  run git -C "$worktree" merge --ff-only "$export_ref"
  run git -C "$worktree" rebase "origin/$base_branch"
  local exported_commit
  exported_commit="$(git -C "$worktree" rev-parse HEAD)"
  run rm -f "$host_bundle"

  if ! $dry_run; then
    update_state "$id" \
      '.hostWorktree = $worktree | .exportedCommit = $commit' \
      --arg worktree "$worktree" \
      --arg commit "$exported_commit"
  fi
  note "exported to $worktree at $exported_commit"
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
  [[ -z "$("$sbx" exec "$sandbox" -- git -C "$repo_dir" status --porcelain)" ]] ||
    die "sandbox repository has uncommitted changes"

  local bundle="${state_root}/${id}-sync.bundle"
  run git -C "$worktree" bundle create "$bundle" "$branch" "^$base_sha"
  run git -C "$worktree" bundle verify "$bundle"
  run "$sbx" cp "$(win_path "$bundle")" "$sandbox:/tmp/sbx-work-${id}-sync.bundle"
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
  seed)
    (($# >= 2 && $# <= 3)) || die "seed requires WORK_ITEM SLUG [REPO]"
    acquire_lock
    seed "$@"
    ;;
  ado-install)
    (($# >= 3)) || die "ado-install requires WORK_ITEM -- PACKAGE_MANAGER [ARG...]"
    acquire_lock
    ado_install "$@"
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
