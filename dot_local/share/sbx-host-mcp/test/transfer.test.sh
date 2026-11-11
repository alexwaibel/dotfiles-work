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
run_export_fixture() {
  FAKE_VM_COMMIT="$export_vm_commit" \
    FAKE_VM_BUNDLE="$export_bundle" \
    FAKE_WINDOWS_GIT_LOG="$fake_windows_git_log" \
    SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN="$fake_export_sbx" \
    SBX_WORK_WINDOWS_GIT_BIN="$fake_windows_git" \
    bash "$script" export "${1:-130}"
}

run_export_fixture 130 >/dev/null
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

jq 'del(.hostWorktree, .exportedCommit, .patchPreserved, .pendingExport)' \
  "${state_root}/130.json" >"${state_root}/130.json.tmp"
mv "${state_root}/130.json.tmp" "${state_root}/130.json"
expect_success "recover legacy first export after a completed equivalent rebase" \
  run_export_fixture

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

conflict_vm="${tmp_dir}/conflict-vm"
conflict_branch="users/alwaibel/agent/140-export-conflict"
git clone -q "$export_remote" "$conflict_vm"
git -C "$conflict_vm" config user.name "VM Agent"
git -C "$conflict_vm" config user.email "agent@example.com"
conflict_base="$(git -C "$conflict_vm" rev-parse HEAD)"
git -C "$conflict_vm" checkout -qb "$conflict_branch"
printf 'base\nagent index entry\n' >"${conflict_vm}/base.txt"
printf 'initial change\n' >"${conflict_vm}/recovered.txt"
git -C "$conflict_vm" add base.txt recovered.txt
git -C "$conflict_vm" commit -qm "Add change and temporary index entry"
printf 'base\n' >"${conflict_vm}/base.txt"
printf 'final change\n' >"${conflict_vm}/recovered.txt"
git -C "$conflict_vm" commit -qam "Finalize change and remove index entry"
export_vm_commit="$(git -C "$conflict_vm" rev-parse HEAD)"
git -C "$conflict_vm" bundle create "$export_bundle" "$conflict_branch" "^$conflict_base"

printf 'base\ntarget index entry\n' >"${export_repo}/base.txt"
git -C "$export_repo" commit -qam "Advance target index"
git -C "$export_repo" push -qu origin master
conflict_target="$(git -C "$export_repo" rev-parse HEAD)"
conflict_worktree="${repos_root}/worktrees/export-repo/140-export-conflict"
jq -n \
  --arg branch "$conflict_branch" \
  --arg base "$conflict_base" \
  '{
    workItem: "140", slug: "export-conflict", repo: "export-repo",
    sandbox: "wi-140-vm", branch: $branch, baseBranch: "master",
    baseSha: $base, repoDir: "/home/agent/workspace/export-repo"
  }' >"${state_root}/140.json"

expect_failure "first export stops on a real rebase conflict" run_export_fixture 140
if jq -e --arg source "$export_vm_commit" --arg target "$conflict_target" \
  --arg worktree "$conflict_worktree" \
  '.pendingExport.sourceCommit == $source and
   .pendingExport.targetCommit == $target and
   .hostWorktree == $worktree and
   .patchPreserved == false and .exportedCommit == null' \
  "${state_root}/140.json" >/dev/null; then
  record_pass "conflicting first export records pending provenance, not success"
else
  record_fail "conflicting first export records pending provenance, not success"
fi

cp "${state_root}/140.json" "${tmp_dir}/pending-export.json"
expect_failure "retry preserves an unresolved rebase" run_export_fixture 140
if cmp -s "${state_root}/140.json" "${tmp_dir}/pending-export.json" &&
  [[ -n "$(git -C "$conflict_worktree" diff --name-only --diff-filter=U)" ]]; then
  record_pass "unresolved retry leaves conflict and metadata untouched"
else
  record_fail "unresolved retry leaves conflict and metadata untouched"
fi

git -C "$conflict_worktree" restore --source=origin/master --staged --worktree -- base.txt
expect_failure "rebase reaches the temporary-entry removal conflict" \
  env GIT_EDITOR=true git -C "$conflict_worktree" rebase --continue
git -C "$conflict_worktree" restore --source=origin/master --staged --worktree -- base.txt
GIT_EDITOR=true git -C "$conflict_worktree" rebase --continue >/dev/null
resolved_head="$(git -C "$conflict_worktree" rev-parse HEAD)"

git -C "$conflict_worktree" commit -q --allow-empty -m "Unrecorded host history"
unrecorded_head="$(git -C "$conflict_worktree" rev-parse HEAD)"
expect_failure "pending recovery rejects equal patches with extra host history" \
  run_export_fixture 140
if [[ "$(git -C "$conflict_worktree" rev-parse HEAD)" == "$unrecorded_head" ]] &&
  cmp -s "${state_root}/140.json" "${tmp_dir}/pending-export.json"; then
  record_pass "rejected pending recovery preserves host history and metadata"
else
  record_fail "rejected pending recovery preserves host history and metadata"
fi
git -C "$conflict_worktree" reset --hard "$resolved_head" >/dev/null

jq '.pendingExport.sourceCommit = "different-source"' \
  "${state_root}/140.json" >"${state_root}/140.json.tmp"
mv "${state_root}/140.json.tmp" "${state_root}/140.json"
expect_failure "pending recovery rejects a mismatched source" run_export_fixture 140
cp "${tmp_dir}/pending-export.json" "${state_root}/140.json"

expect_success "recover first export after preserving target-only index changes" \
  run_export_fixture 140
if jq -e --arg head "$resolved_head" \
  '.exportedCommit == $head and .patchPreserved == true and
   .pendingExport == null' "${state_root}/140.json" >/dev/null &&
  [[ "$(cat "${conflict_worktree}/base.txt")" == $'base\ntarget index entry' ]] &&
  [[ "$(cat "${conflict_worktree}/recovered.txt")" == "final change" ]]; then
  record_pass "successful recovery records verification and retains target content"
else
  record_fail "successful recovery records verification and retains target content"
fi

finish_tests
