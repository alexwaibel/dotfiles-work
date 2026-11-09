#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

source "$(dirname "${BASH_SOURCE[0]}")/shell-test-helpers.sh"
setup_fixture

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
  "repoDir": "/home/agent/workspace/export-repo"
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


finish_tests
