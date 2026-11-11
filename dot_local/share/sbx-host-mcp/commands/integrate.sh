# shellcheck shell=bash
# shellcheck disable=SC2016,SC2154

integrate_work() {
  local id="$1"
  validate_work_item "$id"
  local repo branch base_branch base_sha slug repo_path export_ref vm_head
  repo="$(state_value "$id" '.repo')"
  branch="$(state_value "$id" '.branch')"
  base_branch="$(state_value "$id" '.baseBranch')"
  base_sha="$(state_value "$id" '.baseSha')"
  slug="$(state_value "$id" '.slug')"
  repo_path="$(canonical_repo "$repo")"
  vm_head="$(state_value "$id" '.importedCommit')"
  export_ref="$(state_value "$id" '.importedRef')"
  [[ "$export_ref" == "refs/sbx-work/imports/$id/$vm_head" &&
    "$(git -C "$repo_path" rev-parse "$export_ref")" == "$vm_head" ]] ||
    die "imported ref does not match the recorded VM commit"

  local worktree="${repos_root}/worktrees/${repo}/${id}-${slug}"
  if [[ -d "$worktree" ]]; then
    [[ -z "$(git -C "$worktree" status --porcelain)" ]] ||
      die "host worktree has uncommitted changes"
    [[ "$(git -C "$worktree" branch --show-current)" == "$branch" ]] ||
      die "host worktree is not on the expected branch"
    [[ ! -d "$(git -C "$worktree" rev-parse --git-path rebase-merge)" &&
      ! -d "$(git -C "$worktree" rev-parse --git-path rebase-apply)" ]] ||
      die "finish or abort the host rebase before integrating again"
  fi

  run git -C "$repo_path" fetch origin
  if [[ ! -d "$worktree" ]]; then
    if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then
      run git -C "$repo_path" worktree add "$worktree" "$branch"
    else
      run git -C "$repo_path" worktree add "$worktree" -b "$branch" "$base_sha"
    fi
  fi

  local original_base original_patch_id target_commit
  target_commit="$(git -C "$worktree" rev-parse "origin/$base_branch")"
  original_base="$(git -C "$worktree" merge-base "$target_commit" "$export_ref")"
  original_patch_id="$(
    git -C "$worktree" diff "$original_base" "$export_ref" |
      git patch-id --stable | awk '{print $1}'
  )"
  [[ -n "$original_patch_id" ]] || die "imported branch has no patch to verify"
  if git -C "$worktree" merge-base --is-ancestor HEAD "$export_ref"; then
    run git -C "$worktree" merge --ff-only "$export_ref"
  else
    local previous_integrated host_base host_patch_id host_head
    previous_integrated="$(read_state "$id" | jq -r '.integratedCommit // .exportedCommit // empty')"
    host_head="$(git -C "$worktree" rev-parse HEAD)"
    host_base="$(git -C "$worktree" merge-base "$target_commit" HEAD)"
    if [[ -z "$previous_integrated" || "$host_head" != "$previous_integrated" ]]; then
      local pending_target original_history host_history
      if read_state "$id" | jq -e '(.pendingIntegration // .pendingExport) != null' >/dev/null; then
        read_state "$id" | jq -e \
          --arg source "$vm_head" --arg base "$original_base" \
          --arg patch "$original_patch_id" --arg worktree "$worktree" \
          '(.pendingIntegration // .pendingExport) as $pending |
           $pending.sourceCommit == $source and
           $pending.sourceBase == $base and
           $pending.patchId == $patch and .hostWorktree == $worktree' \
          >/dev/null ||
          die "pending integration does not match the imported patch; preserve both branches for review"
        pending_target="$(state_value "$id" '(.pendingIntegration // .pendingExport).targetCommit')"
        git -C "$worktree" merge-base --is-ancestor "$pending_target" "$host_base" ||
          die "host branch is not based on the pending integration target"
      else
        # Older exports did not record pending state before rebasing.
        [[ -z "$previous_integrated" &&
          "$(git -C "$worktree" reflog -1 --format=%gs)" == "rebase (finish): returning to refs/heads/$branch" ]] ||
          die "host branch changed since the last integration; preserve both branches for review"
      fi
      [[ -z "$(git -C "$worktree" rev-list --merges "$original_base..$export_ref")" &&
        -z "$(git -C "$worktree" rev-list --merges "$host_base..HEAD")" ]] ||
        die "cannot recover an integration with merged history"
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
        die "host commit lineage changed during integration; preserve both branches for review"
      note "verified commit lineage for the interrupted integration"
    fi
    host_patch_id="$(
      git -C "$worktree" diff "$host_base" HEAD |
        git patch-id --stable | awk '{print $1}'
    )"
    [[ "$host_patch_id" == "$original_patch_id" ]] ||
      die "host branch diverged from the imported patch; preserve both branches for review"
    note "host branch already contains the equivalent rebased VM patch"
  fi
  if ! $dry_run; then
    update_state "$id" \
      '.hostWorktree = $worktree | .patchPreserved = false |
       .pendingIntegration = {
         sourceCommit: $source, sourceBase: $base,
         targetCommit: $target, patchId: $patch
       } | del(.pendingExport)' \
      --arg worktree "$worktree" --arg source "$vm_head" \
      --arg base "$original_base" --arg target "$target_commit" \
      --arg patch "$original_patch_id"
  fi
  run git -C "$worktree" rebase "$target_commit"
  local integrated_commit rebased_patch_id
  integrated_commit="$(git -C "$worktree" rev-parse HEAD)"
  rebased_patch_id="$(
    git -C "$worktree" diff "$target_commit" "$integrated_commit" |
      git patch-id --stable | awk '{print $1}'
  )"
  [[ "$rebased_patch_id" == "$original_patch_id" ]] ||
    die "integration changed the VM patch"
  if ! $dry_run; then
    update_state "$id" \
      '.hostWorktree = $worktree | .integratedCommit = $commit |
       .patchPreserved = true | del(.pendingIntegration, .pendingExport, .exportedCommit)' \
      --arg worktree "$worktree" --arg commit "$integrated_commit"
  fi
  note "integrated at $worktree at $integrated_commit; VM patch preserved"
}
