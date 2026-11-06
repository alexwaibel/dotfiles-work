#!/usr/bin/env bash

set -euo pipefail

script="${1:-${HOME}/.local/bin/sbx-work}"
pass=0
fail=0

expect_success() {
  local description="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    printf 'PASS: %s\n' "$description"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s\n' "$description"
    printf '%s\n' "$output"
    fail=$((fail + 1))
  fi
}

expect_failure() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s\n' "$description"
    fail=$((fail + 1))
  else
    printf 'PASS: %s\n' "$description"
    pass=$((pass + 1))
  fi
}

expect_success "shell syntax" bash -n "$script"
expect_success "help" bash "$script" --help
expect_failure "missing command" bash "$script"
expect_failure "unknown command" bash "$script" unknown
expect_failure "invalid seed work item" bash "$script" --dry-run seed abc valid-slug repo
expect_failure "invalid slug" bash "$script" --dry-run seed 123 Invalid_Slug repo

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

repos_root="${tmp_dir}/repos"
state_root="${tmp_dir}/state"
repo="${repos_root}/example-repo"
remote="${tmp_dir}/remote.git"
mkdir -p "$repo"
git init -q --bare "$remote"
git -C "$repo" init -q -b master
git -C "$repo" config user.name "Test User"
git -C "$repo" config user.email "test@example.com"
printf 'test\n' >"${repo}/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm "Initial commit"
git -C "$repo" remote add origin "$remote"
git -C "$repo" push -qu origin master
git --git-dir="$remote" symbolic-ref HEAD refs/heads/master
git -C "$repo" remote set-head origin --auto >/dev/null

dry_run_output="$(
  SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN=/bin/true \
  bash "$script" --dry-run seed 123 valid-slug example-repo
)"
if [[ "$dry_run_output" == *"create --clone --name wi-123-vm --static-mcp none --skills off copilot"* ]] &&
  [[ "$dry_run_output" != *"example-repo.bundle"* ]] &&
  [[ "$dry_run_output" == *"users/alwaibel/agent/123-valid-slug"* ]] &&
  [[ "$dry_run_output" != *"ADO_NPM_TOKEN"* ]] &&
  [[ ! -e "${state_root}/123.json" ]]; then
  printf 'PASS: seed dry-run plan\n'
  pass=$((pass + 1))
else
  printf 'FAIL: seed dry-run plan\n'
  fail=$((fail + 1))
fi

mkdir -p "$state_root"
cat >"${state_root}/125.json" <<'EOF'
{
  "workItem": "125",
  "repo": "example-repo",
  "sandbox": "wi-125-vm"
}
EOF
fake_sbx="${tmp_dir}/fake-sbx"
fake_sbx_log="${tmp_dir}/fake-sbx.log"
cat >"$fake_sbx" <<EOF
#!/usr/bin/env bash
command="\$1"
shift
[[ "\${1:-}" == "--no-input" ]] && shift
set -- "\$command" "\$@"
printf '%s\n' "\$*" >>"$fake_sbx_log"
if [[ "\${1:-}" == "exec" ]]; then
  printf 'forwarded:%s:%s\n' "\${WSLENV:-}" "\${#ADO_NPM_TOKEN}" >>"$fake_sbx_log"
  [[ "\$*" == *"copilot --yolo"* ]] && printf 'agent completed task\n'
  [[ "\$*" == *"-- pwd" ]] && printf '/home/agent/workspace/example-repo\n'
fi
if [[ "\${1:-}" == "ls" ]]; then
  [[ -n "\${FAKE_SBX_LIST:-}" ]] && printf '%s\n' "\$FAKE_SBX_LIST"
  exit 0
fi
if [[ "\${FAKE_SBX_FAIL_EXEC:-false}" == "true" && "\${1:-}" == "exec" ]]; then
  exit 1
fi
EOF
chmod u+x "$fake_sbx"
SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN="$fake_sbx" \
  bash "$script" seed 125 fresh-seed example-repo >/dev/null
if [[ "$(jq -r '.slug' "${state_root}/125.json")" == "fresh-seed" ]] &&
  grep -q '^create --clone --name wi-125-vm --static-mcp none --skills off copilot ' "$fake_sbx_log"; then
  printf 'PASS: replace stale unexported metadata\n'
  pass=$((pass + 1))
else
  printf 'FAIL: replace stale unexported metadata\n'
  fail=$((fail + 1))
fi

inspect_present_output="$(
  FAKE_SBX_LIST=wi-125-vm \
    SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN="$fake_sbx" \
    bash "$script" inspect 125
)"
if [[ "$(jq -r '.sandboxStatus' <<<"$inspect_present_output")" == "present" ]]; then
  printf 'PASS: inspect present sandbox\n'
  pass=$((pass + 1))
else
  printf 'FAIL: inspect present sandbox\n'
  fail=$((fail + 1))
fi

cat >"${state_root}/126.json" <<'EOF'
{
  "workItem": "126",
  "repo": "example-repo",
  "sandbox": "wi-126-vm",
  "hostWorktree": "/tmp/preserved-worktree"
}
EOF
expect_failure "preserve stale exported metadata" \
  env \
  SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN="$fake_sbx" \
  bash "$script" seed 126 preserved-work example-repo
if [[ -f "${state_root}/126.json" ]]; then
  printf 'PASS: stale exported metadata remains\n'
  pass=$((pass + 1))
else
  printf 'FAIL: stale exported metadata remains\n'
  fail=$((fail + 1))
fi

inspect_exported_output="$(
  SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN="$fake_sbx" \
    bash "$script" inspect 126
)"
if [[ "$(jq -r '.sandboxStatus' <<<"$inspect_exported_output")" == "missing-exported" ]]; then
  printf 'PASS: inspect missing exported sandbox\n'
  pass=$((pass + 1))
else
  printf 'FAIL: inspect missing exported sandbox\n'
  fail=$((fail + 1))
fi

cat >"${state_root}/128.json" <<'EOF'
{
  "workItem": "128",
  "repo": "example-repo",
  "sandbox": "wi-128-vm",
  "privateValue": "must-not-leak"
}
EOF
inspect_stale_output="$(
  SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN="$fake_sbx" \
    bash "$script" inspect 128
)"
if [[ "$(jq -r '.sandboxStatus' <<<"$inspect_stale_output")" == "missing-unexported" ]] &&
  [[ "$inspect_stale_output" != *"must-not-leak"* ]]; then
  printf 'PASS: inspect missing unexported sandbox\n'
  pass=$((pass + 1))
else
  printf 'FAIL: inspect missing unexported sandbox\n'
  fail=$((fail + 1))
fi

: >"$fake_sbx_log"
expect_failure "clean failed seed" \
  env \
  FAKE_SBX_FAIL_EXEC=true \
  SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN="$fake_sbx" \
  bash "$script" seed 127 failed-seed example-repo
if [[ ! -e "${state_root}/127.json" ]] &&
  grep -q '^rm --force wi-127-vm$' "$fake_sbx_log"; then
  printf 'PASS: failed seed removes sandbox and metadata\n'
  pass=$((pass + 1))
else
  printf 'FAIL: failed seed removes sandbox and metadata\n'
  fail=$((fail + 1))
fi

cat >"${repo}/package.json" <<'EOF'
{
  "packageManager": "yarn@4.14.0"
}
EOF
cat >"${repo}/.yarnrc.yml" <<'EOF'
npmScopes:
  private:
    npmRegistryServer: "https://pkgs.dev.azure.com/example/project/_packaging/feed/npm/registry/"
    npmAuthToken: "${ADO_NPM_TOKEN}"
EOF
printf '__metadata:\n  version: 8\n' >"${repo}/yarn.lock"
git -C "$repo" add package.json .yarnrc.yml yarn.lock
git -C "$repo" commit -qm "Add private package metadata"
git -C "$repo" remote set-url origin \
  https://example.visualstudio.com/DefaultCollection/Project/_git/example-repo

private_seed_output="$(
  SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN=/bin/true \
    bash "$script" --dry-run seed 124 private-restore example-repo
)"
if [[ "$private_seed_output" == *"restoring private dependencies before agent startup"* ]] &&
  [[ "$private_seed_output" == *"ADO_NPM_TOKEN=<redacted>"* ]] &&
  [[ "$private_seed_output" == *"yarn install --immutable"* ]] &&
  [[ "$private_seed_output" == *"vsassets.io"* ]] &&
  [[ "$private_seed_output" == *"YARN_ENABLE_SCRIPTS=false"* ]] &&
  [[ ! -e "${state_root}/124.json" ]]; then
  printf 'PASS: private dependency seed preflight\n'
  pass=$((pass + 1))
else
  printf 'FAIL: private dependency seed preflight\n'
  fail=$((fail + 1))
fi

fake_powershell="${tmp_dir}/powershell.exe"
fake_powershell_log="${tmp_dir}/powershell.log"
cat >"$fake_powershell" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$fake_powershell_log"
printf 'package-read-token\\r\\n'
EOF
chmod u+x "$fake_powershell"
: >"$fake_sbx_log"
git -C "$repo" remote set-url origin "$remote"
SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN="$fake_sbx" \
  SBX_WORK_POWERSHELL_BIN="$fake_powershell" \
  SBX_WORK_ADO_ORGANIZATION=example \
  bash "$script" seed 129 windows-auth example-repo >/dev/null
if [[ -f "${state_root}/129.json" ]] &&
  grep -q 'azureauth ado pat' "$fake_powershell_log" &&
  grep -q -- '-e ADO_NPM_TOKEN' "$fake_sbx_log" &&
  grep -Eq '^forwarded:.*ADO_NPM_TOKEN:[1-9][0-9]*$' "$fake_sbx_log" &&
  grep -q 'node_modules/.yarn-state.yml' "$fake_sbx_log" &&
  ! grep -q 'package-read-token' "$fake_sbx_log"; then
  printf 'PASS: Windows auth token stays out of VM command arguments\n'
  pass=$((pass + 1))
else
  printf 'FAIL: Windows auth token stays out of VM command arguments\n'
  fail=$((fail + 1))
fi

mkdir -p "${state_root}/tasks"
cat >"${state_root}/131.json" <<'EOF'
{
  "workItem": "131",
  "repo": "example-repo",
  "sandbox": "wi-131-vm",
  "repoDir": "/home/agent/workspace/example-repo"
}
EOF
task_id="task-11111111-1111-1111-1111-111111111111"
cat >"${state_root}/tasks/${task_id}.json" <<EOF
{
  "taskId": "$task_id",
  "workItem": 131,
  "status": "queued"
}
EOF
printf 'Implement the bounded task.' >"${state_root}/tasks/${task_id}.prompt"
: >"${state_root}/tasks/${task_id}.log"
SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN="$fake_sbx" \
  bash "$script" dispatch 131 "$task_id"
if [[ "$(jq -r '.status' "${state_root}/tasks/${task_id}.json")" == "completed" ]] &&
  grep -q 'agent completed task' "${state_root}/tasks/${task_id}.log" &&
  [[ ! -e "${state_root}/tasks/${task_id}.prompt" ]]; then
  printf 'PASS: dispatch records task status and logs\n'
  pass=$((pass + 1))
else
  printf 'FAIL: dispatch records task status and logs\n'
  fail=$((fail + 1))
fi

export_repo="${repos_root}/export-repo"
export_remote="${tmp_dir}/export-remote.git"
export_vm="${tmp_dir}/export-vm"
export_bundle="${tmp_dir}/export.bundle"
git init -q --bare "$export_remote"
git -C "$repos_root" init -q -b master export-repo
git -C "$export_repo" config user.name "Test User"
git -C "$export_repo" config user.email "test@example.com"
printf 'base\n' >"${export_repo}/base.txt"
git -C "$export_repo" add base.txt
git -C "$export_repo" commit -qm "Base"
git -C "$export_repo" remote add origin "$export_remote"
git -C "$export_repo" push -qu origin master
git --git-dir="$export_remote" symbolic-ref HEAD refs/heads/master
git -C "$export_repo" remote set-head origin --auto >/dev/null
export_base="$(git -C "$export_repo" rev-parse HEAD)"

git clone -q "$export_remote" "$export_vm"
git -C "$export_vm" config user.name "VM Agent"
git -C "$export_vm" config user.email "agent@example.com"
export_branch="users/alwaibel/agent/130-export-topology"
git -C "$export_vm" checkout -qb "$export_branch" "$export_base"
printf 'agent\n' >"${export_vm}/agent.txt"
git -C "$export_vm" add agent.txt
git -C "$export_vm" commit -qm "Agent change"
export_vm_commit="$(git -C "$export_vm" rev-parse HEAD)"
git -C "$export_vm" bundle create "$export_bundle" "$export_branch" "^$export_base"

printf 'advanced\n' >"${export_repo}/advanced.txt"
git -C "$export_repo" add advanced.txt
git -C "$export_repo" commit -qm "Advance master"
git -C "$export_repo" push -qu origin master
export_origin_head="$(git -C "$export_repo" rev-parse HEAD)"

cat >"${state_root}/130.json" <<EOF
{
  "workItem": "130",
  "slug": "export-topology",
  "repo": "export-repo",
  "sandbox": "wi-130-vm",
  "branch": "$export_branch",
  "baseBranch": "master",
  "baseSha": "$export_base",
  "repoDir": "/home/agent/workspace/export-repo",
  "transferMode": "clone"
}
EOF
fake_export_sbx="${tmp_dir}/fake-export-sbx"
cat >"$fake_export_sbx" <<'EOF'
#!/usr/bin/env bash
command="$1"
shift
[[ "${1:-}" == "--no-input" ]] && shift
set -- "$command" "$@"
if [[ "$1" == "exec" ]]; then
  case "$*" in
    *"rev-parse HEAD"*)
      printf '%s\n' "$FAKE_VM_COMMIT"
      ;;
  esac
  exit 0
fi
if [[ "$1" == "cp" ]]; then
  if [[ "$2" == *:* ]]; then
    cp "$FAKE_VM_BUNDLE" "$(wslpath -u "$3")"
  fi
  exit 0
fi
exit 0
EOF
chmod u+x "$fake_export_sbx"
fake_windows_git="${tmp_dir}/fake-windows-git"
fake_windows_git_log="${tmp_dir}/fake-windows-git.log"
cat >"$fake_windows_git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_WINDOWS_GIT_LOG"
[[ "$1" == "-C" ]] || exit 2
repo="$2"
command="$3"
case "$command" in
  fetch)
    git -C "$repo" fetch "$FAKE_VM_BUNDLE" "$5"
    ;;
  push)
    exit 0
    ;;
  *)
    git "$@"
    ;;
esac
EOF
chmod u+x "$fake_windows_git"
FAKE_VM_COMMIT="$export_vm_commit" \
  FAKE_VM_BUNDLE="$export_bundle" \
  FAKE_WINDOWS_GIT_LOG="$fake_windows_git_log" \
  SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN="$fake_export_sbx" \
  SBX_WORK_WINDOWS_GIT_BIN="$fake_windows_git" \
  bash "$script" export 130 >/dev/null
export_worktree="${repos_root}/worktrees/export-repo/130-export-topology"
exported_head="$(git -C "$export_worktree" rev-parse HEAD)"
if git -C "$export_worktree" merge-base --is-ancestor \
  "$export_origin_head" "$exported_head" &&
  [[ -f "${export_worktree}/agent.txt" ]] &&
  [[ "$(jq -r '.patchPreserved' "${state_root}/130.json")" == "true" ]] &&
  [[ "$exported_head" != "$export_vm_commit" ]]; then
  printf 'PASS: export rebases VM commit after advanced base\n'
  pass=$((pass + 1))
else
  printf 'FAIL: export rebases VM commit after advanced base\n'
  fail=$((fail + 1))
fi

export_iteration_vm="${tmp_dir}/export-iteration-vm"
git clone -q --branch "$export_branch" "$export_worktree" "$export_iteration_vm"
git -C "$export_iteration_vm" config user.name "VM Agent"
git -C "$export_iteration_vm" config user.email "agent@example.com"
printf 'simplified agent\n' >"${export_iteration_vm}/agent.txt"
git -C "$export_iteration_vm" commit -qam "Simplify agent change"
export_vm_commit="$(git -C "$export_iteration_vm" rev-parse HEAD)"
git -C "$export_iteration_vm" bundle create "$export_bundle" "$export_branch" "^$export_base"
printf 'advanced again\n' >"${export_repo}/advanced-again.txt"
git -C "$export_repo" add advanced-again.txt
git -C "$export_repo" commit -qm "Advance master again"
git -C "$export_repo" push -qu origin master

run_export_fixture() {
  FAKE_VM_COMMIT="$export_vm_commit" \
    FAKE_VM_BUNDLE="$export_bundle" \
    FAKE_WINDOWS_GIT_LOG="$fake_windows_git_log" \
    SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN="$fake_export_sbx" \
    SBX_WORK_WINDOWS_GIT_BIN="$fake_windows_git" \
    bash "$script" export 130
}

expect_success "export follow-up excludes upstream commits from stale seed base" \
  run_export_fixture
exported_head="$(git -C "$export_worktree" rev-parse HEAD)"
expect_success "retry verifies already-rebased export without fast-forward" \
  run_export_fixture
if [[ "$(jq -r '.exportedCommit' "${state_root}/130.json")" == "$exported_head" ]] &&
  [[ "$(git -C "$export_worktree" rev-parse HEAD)" == "$exported_head" ]] &&
  [[ "$(cat "${export_worktree}/agent.txt")" == "simplified agent" ]]; then
  printf 'PASS: retry preserves branch and records verified commit\n'
  pass=$((pass + 1))
else
  printf 'FAIL: retry preserves branch and records verified commit\n'
  fail=$((fail + 1))
fi

printf 'unreviewed host change\n' >"${export_worktree}/agent.txt"
expect_failure "export rejects dirty host worktree" run_export_fixture
git -C "$export_worktree" commit -qam "Unreviewed host change"
unreviewed_head="$(git -C "$export_worktree" rev-parse HEAD)"
expect_failure "retry rejects changed host patch" run_export_fixture
if [[ "$(git -C "$export_worktree" rev-parse HEAD)" == "$unreviewed_head" ]] &&
  [[ "$(jq -r '.exportedCommit' "${state_root}/130.json")" == "$exported_head" ]]; then
  printf 'PASS: rejected retry preserves host work and transfer metadata\n'
  pass=$((pass + 1))
else
  printf 'FAIL: rejected retry preserves host work and transfer metadata\n'
  fail=$((fail + 1))
fi
git -C "$export_worktree" revert --no-edit "$unreviewed_head" >/dev/null
reverted_head="$(git -C "$export_worktree" rev-parse HEAD)"
expect_failure "retry rejects equivalent patch with unrecorded history" \
  run_export_fixture
if [[ "$(git -C "$export_worktree" rev-parse HEAD)" == "$reverted_head" ]] &&
  [[ "$(jq -r '.exportedCommit' "${state_root}/130.json")" == "$exported_head" ]]; then
  printf 'PASS: rejected equivalent history preserves recorded export\n'
  pass=$((pass + 1))
else
  printf 'FAIL: rejected equivalent history preserves recorded export\n'
  fail=$((fail + 1))
fi
git -C "$export_worktree" reset --hard "$exported_head" >/dev/null
expect_success "retry accepts the exact recorded export" run_export_fixture

FAKE_VM_COMMIT="$exported_head" \
  FAKE_VM_BUNDLE="$export_bundle" \
  SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN="$fake_export_sbx" \
  bash "$script" sync 130 >/dev/null
if [[ "$(jq -r '.syncedCommit' "${state_root}/130.json")" == "$exported_head" ]]; then
  printf 'PASS: exceptional sync uses verified bundle\n'
  pass=$((pass + 1))
else
  printf 'FAIL: exceptional sync uses verified bundle\n'
  fail=$((fail + 1))
fi

exec 8>"${state_root}/operation.lock"
flock -n 8
expect_failure "reject concurrent operation" \
  env \
  SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN=/bin/true \
  bash "$script" --dry-run seed 124 another-slug example-repo
flock -u 8

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
