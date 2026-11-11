#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

source "$(dirname "${BASH_SOURCE[0]}")/shell-test-helpers.sh"
setup_fixture

branch="users/alwaibel/agent/130-transfer"
host_worktree="${repos_root}/worktrees/example-repo/130-transfer"
vm="${tmp_dir}/vm"
mkdir -p "$(dirname "$host_worktree")"
git -C "$repo" worktree add -qb "$branch" "$host_worktree"
printf 'original PR\n' >"$host_worktree/feature.txt"
git -C "$host_worktree" add feature.txt
git -C "$host_worktree" commit -qm "Original PR"
baseline="$(git -C "$host_worktree" rev-parse HEAD)"
git clone -q --depth=1 --branch "$branch" "file://$repo" "$vm"
git -C "$vm" config user.name "VM Agent"
git -C "$vm" config user.email "agent@example.com"
printf 'follow-up\n' >"$vm/follow-up.txt"
git -C "$vm" add follow-up.txt
git -C "$vm" commit -qm "Follow-up"
vm_head="$(git -C "$vm" rev-parse HEAD)"
canonical_head="$(git -C "$repo" rev-parse HEAD)"
replacement_bundle="$tmp_dir/different.bundle"
git -C "$host_worktree" bundle create "$replacement_bundle" "$branch"

jq -n --arg branch "$branch" --arg base "$baseline" --arg vm "$vm" \
  '{workItem: "130", repo: "example-repo", sandbox: "wi-130-vm",
    branch: $branch, baseSha: $base, repoDir: $vm}' >"$state_root/130.json"

cat >"$fake_sbx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command="$1"
shift
[[ "${1:-}" == "--no-input" ]] && shift
case "$command" in
  exec)
    shift
    [[ "$1" == -- ]] && shift
    exec "$@"
    ;;
  cp)
    source="${1#wi-130-vm:}"
    target="${2#wi-130-vm:}"
    cp "$source" "$target"
    if [[ -n "${REPLACEMENT_BUNDLE:-}" ]]; then
      cp "$REPLACEMENT_BUNDLE" "$target"
    fi
    if [[ "${CORRUPT_COPY:-false}" == true ]]; then
      printf 'corrupt bundle\n' >"$target"
    fi
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod u+x "$fake_sbx"

transfer() {
  SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN="$fake_sbx" \
    bash "$script" "$@"
}

expect_success "import exact VM commit from a shallow clone" transfer export 130
import_ref="refs/sbx-work/imports/130/$vm_head"
if [[ "$(git -C "$repo" rev-parse "$import_ref")" == "$vm_head" &&
  "$(git -C "$repo" rev-parse HEAD)" == "$canonical_head" &&
  "$(git -C "$host_worktree" rev-parse HEAD)" == "$baseline" ]] &&
  jq -e --arg head "$vm_head" --arg ref "$import_ref" \
    '.importedCommit == $head and .importedRef == $ref and .hostWorktree == null' \
    "$state_root/130.json" >/dev/null; then
  record_pass "import records exact SHA without choosing a host worktree or history"
else
  record_fail "import records exact SHA without choosing a host worktree or history"
fi

printf 'upstream\n' >"$repo/upstream.txt"
git -C "$repo" add upstream.txt
git -C "$repo" commit -qm "Advance master"
git -C "$host_worktree" merge --ff-only "$import_ref" >/dev/null
git -C "$host_worktree" rebase master >/dev/null
reviewed_head="$(git -C "$host_worktree" rev-parse HEAD)"
git -C "$repo" remote set-url origin "$tmp_dir/unavailable.git"

# Materialize the old ancestor without connecting it to the shallow VM history.
ancestor="$(git -C "$repo" rev-parse "$baseline^")"
git -C "$repo" cat-file commit "$ancestor" | git -C "$vm" hash-object -t commit -w --stdin >/dev/null
old_bundle="$tmp_dir/old-sync.bundle"
git -C "$host_worktree" bundle create "$old_bundle" "$branch" "^$baseline"
expect_failure "reproduce disconnected-prerequisite rejection" \
  git -C "$vm" bundle verify "$old_bundle"

printf 'local review notes\n' >"$host_worktree/uncommitted.txt"
expect_success "sync explicit reviewed SHA without origin, integration state, or clean host checkout" \
  transfer sync 130 "$reviewed_head"
if [[ "$(git -C "$vm" rev-parse HEAD)" == "$reviewed_head" &&
  "$(git -C "$vm" branch --show-current)" == "$branch" &&
  -f "$vm/upstream.txt" && -f "$host_worktree/uncommitted.txt" ]] &&
  jq -e --arg head "$reviewed_head" '.syncedCommit == $head' "$state_root/130.json" >/dev/null; then
  record_pass "sync verifies exact destination SHA and preserves unrelated host work"
else
  record_fail "sync verifies exact destination SHA and preserves unrelated host work"
fi

cp "$state_root/130.json" "$tmp_dir/verified-state.json"
expect_failure "sync requires an explicit commit" transfer sync 130
expect_failure "sync rejects symbolic revisions" transfer sync 130 HEAD
expect_failure "sync rejects unavailable commits" transfer sync 130 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf 'preserve me\n' >"$vm/local.txt"
expect_failure "sync rejects dirty VM" transfer sync 130 "$reviewed_head"
expect_failure "export rejects dirty VM" transfer export 130
rm "$vm/local.txt"
git -C "$vm" switch -qc unexpected
expect_failure "sync rejects unexpected VM branch" transfer sync 130 "$reviewed_head"
expect_failure "export rejects unexpected VM branch" transfer export 130
git -C "$vm" switch -q "$branch"
if CORRUPT_COPY=true transfer sync 130 "$baseline" >/dev/null 2>&1; then
  record_fail "sync rejects corrupt transport before replacing VM checkout"
else
  record_pass "sync rejects corrupt transport before replacing VM checkout"
fi
if CORRUPT_COPY=true transfer export 130 >/dev/null 2>&1; then
  record_fail "export rejects corrupt transport"
else
  record_pass "export rejects corrupt transport"
fi
if REPLACEMENT_BUNDLE="$replacement_bundle" transfer export 130 >/dev/null 2>&1; then
  record_fail "export rejects a valid bundle with the wrong captured SHA"
else
  record_pass "export rejects a valid bundle with the wrong captured SHA"
fi
if cmp -s "$state_root/130.json" "$tmp_dir/verified-state.json" &&
  [[ "$(git -C "$vm" rev-parse HEAD)" == "$reviewed_head" ]]; then
  record_pass "failed transfers preserve checkout and last verified metadata"
else
  record_fail "failed transfers preserve checkout and last verified metadata"
fi
if compgen -G "$state_root/*.bundle" >/dev/null ||
  [[ -n "$(git -C "$repo" for-each-ref --format='%(refname)' refs/sbx-work/transfers)" ]]; then
  record_fail "transfer cleans temporary bundles and refs"
else
  record_pass "transfer cleans temporary bundles and refs"
fi

finish_tests
