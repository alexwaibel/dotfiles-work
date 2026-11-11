# shellcheck shell=bash
# shellcheck disable=SC2016,SC2154

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
  vm_status="$(sbx_call "$sbx" exec "$sandbox" -- git -C "$repo_dir" status --porcelain)"
  [[ -z "$vm_status" ]] || die "sandbox repository has uncommitted changes"

  local vm_head
  vm_head="$(sbx_call "$sbx" exec "$sandbox" -- git -C "$repo_dir" rev-parse HEAD)"
  [[ "$vm_head" != "$base_sha" ]] || die "sandbox branch has no commits to export"

  local export_ref="refs/remotes/sbx-work/${id}"
  local sandbox_remote="sandbox-${sandbox}"
  run windows_git "$repo_path" fetch \
    "$sandbox_remote" "+$branch:$export_ref"
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

  [[ "$(git -C "$worktree" rev-parse "$export_ref")" == "$vm_head" ]] ||
    die "imported branch does not match sandbox HEAD"
  local original_base original_patch_id target_commit
  target_commit="$(git -C "$worktree" rev-parse "origin/$base_branch")"
  original_base="$(git -C "$worktree" merge-base "$target_commit" "$export_ref")"
  original_patch_id="$(
    git -C "$worktree" diff "$original_base" "$export_ref" |
      git patch-id --stable |
      awk '{print $1}'
  )"
  [[ -n "$original_patch_id" ]] || die "exported branch has no patch to verify"
  if git -C "$worktree" merge-base --is-ancestor HEAD "$export_ref"; then
    run git -C "$worktree" merge --ff-only "$export_ref"
  else
    local previous_exported host_base host_patch_id host_head
    previous_exported="$(read_state "$id" | jq -r '.exportedCommit // empty')"
    host_head="$(git -C "$worktree" rev-parse HEAD)"
    host_base="$(git -C "$worktree" merge-base "$target_commit" HEAD)"
    if [[ -z "$previous_exported" || "$host_head" != "$previous_exported" ]]; then
      local pending_target original_history host_history
      if read_state "$id" | jq -e '.pendingExport != null' >/dev/null; then
        read_state "$id" | jq -e \
          --arg source "$vm_head" --arg base "$original_base" \
          --arg patch "$original_patch_id" --arg worktree "$worktree" \
          '.pendingExport.sourceCommit == $source and
           .pendingExport.sourceBase == $base and
           .pendingExport.patchId == $patch and .hostWorktree == $worktree' \
          >/dev/null ||
          die "pending export does not match the VM patch; preserve both branches for review"
        pending_target="$(state_value "$id" '.pendingExport.targetCommit')"
        git -C "$worktree" merge-base --is-ancestor "$pending_target" "$host_base" ||
          die "host branch is not based on the pending export target"
      else
        # Older exports did not record pending state before rebasing.
        [[ -z "$previous_exported" &&
          "$(git -C "$worktree" reflog -1 --format=%gs)" == "rebase (finish): returning to refs/heads/$branch" ]] ||
          die "host branch changed since the last recorded export; preserve both branches for review"
      fi
      [[ -z "$(git -C "$worktree" rev-list --merges "$original_base..$export_ref")" &&
        -z "$(git -C "$worktree" rev-list --merges "$host_base..HEAD")" ]] ||
        die "cannot recover an export with merged history"
      original_history="$(
        git -C "$worktree" log --reverse --no-show-signature --no-notes \
          --format='%an%x00%ae%x00%aI%x00%B%x00' "$original_base..$export_ref" |
          git hash-object --stdin
      )"
      host_history="$(
        git -C "$worktree" log --reverse --no-show-signature --no-notes \
          --format='%an%x00%ae%x00%aI%x00%B%x00' "$host_base..HEAD" |
          git hash-object --stdin
      )"
      [[ "$host_history" == "$original_history" ]] ||
        die "host commit lineage changed during export; preserve both branches for review"
      note "verified commit lineage for the interrupted export"
    fi
    host_patch_id="$(
      git -C "$worktree" diff "$host_base" HEAD |
        git patch-id --stable |
        awk '{print $1}'
    )"
    [[ "$host_patch_id" == "$original_patch_id" ]] ||
      die "host branch diverged from the VM patch; preserve both branches for review"
    note "host branch already contains the equivalent rebased VM patch"
  fi
  if ! $dry_run; then
    update_state "$id" \
      '.hostWorktree = $worktree | .patchPreserved = false |
       .pendingExport = {
         sourceCommit: $source, sourceBase: $base,
         targetCommit: $target, patchId: $patch
       }' \
      --arg worktree "$worktree" --arg source "$vm_head" \
      --arg base "$original_base" --arg target "$target_commit" \
      --arg patch "$original_patch_id"
  fi
  run git -C "$worktree" rebase "$target_commit"
  local exported_commit
  exported_commit="$(git -C "$worktree" rev-parse HEAD)"
  local rebased_patch_id
  rebased_patch_id="$(
    git -C "$worktree" diff "$target_commit" "$exported_commit" |
      git patch-id --stable |
      awk '{print $1}'
  )"
  [[ "$rebased_patch_id" == "$original_patch_id" ]] ||
    die "rebased export changed the VM patch"

  if ! $dry_run; then
    update_state "$id" \
      '.hostWorktree = $worktree |
       .exportedCommit = $commit |
       .patchPreserved = true | del(.pendingExport)' \
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
