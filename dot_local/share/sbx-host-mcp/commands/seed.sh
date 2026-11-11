# shellcheck shell=bash
# shellcheck disable=SC2016,SC2154

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

seed() {
  local id="$1"
  local slug="$2"
  local reuse_existing_branch="${4:-false}"
  local repo
  repo="$(resolve_repo "${3:-}")"
  validate_work_item "$id"
  validate_slug "$slug"
  [[ "$reuse_existing_branch" == "true" || "$reuse_existing_branch" == "false" ]] ||
    die "reuse-existing-branch must be true or false"

  local repo_path sbx base_branch sandbox branch repo_dir git_name git_email
  local metadata_to_backup="" metadata_backup=""
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
    if [[ "$reuse_existing_branch" == "true" && -f "$(state_file "$id")" ]]; then
      local metadata recorded_sandbox recorded_repo recorded_branch
      metadata="$(state_file "$id")"
      recorded_sandbox="$(jq -er '.sandbox' "$metadata")"
      recorded_repo="$(jq -er '.repo' "$metadata")"
      recorded_branch="$(jq -er '.branch' "$metadata")"
      [[ "$recorded_sandbox" == "$sandbox" &&
        "$recorded_repo" == "$repo" &&
        "$recorded_branch" == "$branch" ]] ||
        die "existing metadata does not match the requested PR branch"
      sandbox_exists "$sbx" "$sandbox" &&
        die "sandbox already exists for work item $id"
      metadata_to_backup="$metadata"
    else
      clear_stale_state "$id" "$sbx" "$sandbox"
      sandbox_exists "$sbx" "$sandbox" &&
        die "sandbox already exists without metadata: $sandbox"
    fi
  else
    [[ "$reuse_existing_branch" == "true" || ! -e "$(state_file "$id")" ]] ||
      die "metadata already exists: $(state_file "$id")"
  fi

  ensure_canonical_ready "$repo_path" "$base_branch"
  run sbx_prepare_clone "$sbx" "$repo_path"
  note "refreshing ${repo}/${base_branch}"
  run git -C "$repo_path" fetch origin
  run git -C "$repo_path" merge --ff-only "origin/$base_branch"
  local base_sha
  if [[ "$reuse_existing_branch" == "true" ]]; then
    git -C "$repo_path" show-ref --verify --quiet "refs/remotes/origin/$branch" ||
      die "remote PR branch not found: origin/$branch"
    base_sha="$(git -C "$repo_path" rev-parse "origin/$branch")"
  else
    git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch" &&
      die "local branch already exists: $branch"
    git -C "$repo_path" show-ref --verify --quiet "refs/remotes/origin/$branch" &&
      die "remote branch already exists: $branch"
    base_sha="$(git -C "$repo_path" rev-parse "$base_branch")"
  fi

  local -a install_command=()
  if uses_azure_artifacts "$repo_path"; then
    mapfile -d '' -t install_command < <(detect_install_command "$repo_path")
    ((${#install_command[@]} > 0)) ||
      die "Azure Artifacts is configured but package.json has no supported packageManager"
  fi

  if [[ -n "$metadata_to_backup" ]]; then
    metadata_backup="${metadata_to_backup}.seed-backup"
    mv "$metadata_to_backup" "$metadata_backup"
  fi

  local seed_started=false
  cleanup_incomplete_seed() {
    if $seed_started && ! $dry_run; then
      note "cleaning incomplete sandbox $sandbox"
      sbx_call "$sbx" rm --force "$sandbox" >/dev/null 2>&1 || true
      rm -f "$(state_file "$id")"
    fi
    if [[ -n "$metadata_backup" && -f "$metadata_backup" ]]; then
      mv "$metadata_backup" "$(state_file "$id")"
    fi
  }
  seed_step() {
    local exit_code
    "$@" && return 0
    exit_code=$?
    cleanup_incomplete_seed
    return "$exit_code"
  }

  note "creating clone-mode sandbox $sandbox"
  seed_started=true
  seed_step run sbx_call "$sbx" create \
    --clone \
    --name "$sandbox" \
    --static-mcp none \
    --skills off \
    copilot \
    "$(sbx_host_path "$sbx" "$repo_path")"
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
  local bootstrap="/tmp/sbx-work-${id}-bootstrap.sh"
  seed_step run sbx_copy_to "$sbx" "$sandbox" "$SCRIPT_DIR/vm/bootstrap.sh" "$bootstrap"
  seed_step run sbx_call "$sbx" exec "$sandbox" -- bash "$bootstrap" \
    "$repo_dir" "$branch" "$base_sha" "$git_name" "$git_email" "$reuse_existing_branch"
  seed_step run sbx_call "$sbx" exec "$sandbox" -- rm -f -- "$bootstrap"

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
  [[ -z "$metadata_backup" ]] || rm -f "$metadata_backup"
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
  token="$(package_read_token "$organization" "$id")"
  [[ -n "$token" ]] || die "Windows Azure authentication returned an empty token"
  [[ "$token" != *$'\n'* ]] ||
    die "Windows Azure authentication returned unexpected multi-line output"
  local exit_code=0
  ADO_NPM_TOKEN="$token" sbx_with_env "$sbx" ADO_NPM_TOKEN -- exec \
    -e ADO_NPM_TOKEN \
    -e YARN_ENABLE_SCRIPTS=false \
    -e npm_config_ignore_scripts=true \
    -e PNPM_CONFIG_IGNORE_SCRIPTS=true \
    "$sandbox" -- \
    bash -lc "$PACKAGE_RUNNER" bash "$repo_dir" "${install_command[@]}" ||
    exit_code=$?
  unset token
  [[ "$exit_code" -eq 0 ]] || return "$exit_code"

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
