# shellcheck shell=bash
# shellcheck disable=SC2016,SC2154

export_work() (
  local id="$1"
  validate_work_item "$id"
  local sbx sandbox repo branch base_sha repo_dir repo_path
  sbx="$(find_sbx)"
  sandbox="$(state_value "$id" '.sandbox')"
  repo="$(state_value "$id" '.repo')"
  branch="$(state_value "$id" '.branch')"
  base_sha="$(state_value "$id" '.baseSha')"
  repo_dir="$(state_value "$id" '.repoDir')"
  repo_path="$(canonical_repo "$repo")"

  local vm_status
  vm_status="$(sbx_call "$sbx" exec "$sandbox" -- git -C "$repo_dir" status --porcelain)"
  [[ -z "$vm_status" ]] || die "sandbox repository has uncommitted changes"
  [[ "$(sbx_call "$sbx" exec "$sandbox" -- git -C "$repo_dir" branch --show-current)" == "$branch" ]] ||
    die "sandbox repository is not on the expected branch"

  local vm_head
  vm_head="$(sbx_call "$sbx" exec "$sandbox" -- git -C "$repo_dir" rev-parse HEAD)"
  [[ "$vm_head" =~ ^[a-f0-9]{40,64}$ ]] || die "sandbox returned an invalid commit"
  [[ "$vm_head" != "$base_sha" ]] || die "sandbox branch has no commits to export"
  local export_ref="refs/sbx-work/imports/$id/$vm_head"
  local vm_bundle="/tmp/sbx-work-${id}-export-${BASHPID}.bundle"
  local bundle="${state_root}/${id}-export.bundle"
  if ! $dry_run; then
    bundle="$(mktemp "${state_root}/${id}-export.XXXXXX.bundle")"
    trap 'rm -f -- "$bundle"; sbx_call "$sbx" exec "$sandbox" -- rm -f -- "$vm_bundle" >/dev/null 2>&1 || true' EXIT
  fi
  run sbx_call "$sbx" exec "$sandbox" -- git -C "$repo_dir" \
    bundle create "$vm_bundle" "$branch" "^$base_sha"
  run sbx_copy_from "$sbx" "$sandbox" "$vm_bundle" "$bundle"
  run git -C "$repo_path" bundle verify "$bundle"
  if ! $dry_run; then
    [[ "$(git -C "$repo_path" bundle list-heads "$bundle" "refs/heads/$branch")" == "$vm_head refs/heads/$branch" ]] ||
      die "bundle does not match the expected sandbox branch and HEAD"
  fi
  run git -C "$repo_path" fetch --no-tags "$bundle" "refs/heads/$branch:$export_ref"
  if ! $dry_run; then
    [[ "$(git -C "$repo_path" rev-parse "$export_ref")" == "$vm_head" ]] ||
      die "imported branch does not match sandbox HEAD"
    update_state "$id" \
      '.importedCommit = $commit | .importedRef = $ref' \
      --arg commit "$vm_head" --arg ref "$export_ref"
  fi
  note "imported exact VM commit $vm_head into $export_ref; host branch unchanged"
)

sync_work() (
  local id="$1"
  local commit="$2"
  validate_work_item "$id"
  [[ "$commit" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]] ||
    die "sync requires a full commit SHA"
  local sbx sandbox branch repo_dir repo_path
  sbx="$(find_sbx)"
  sandbox="$(state_value "$id" '.sandbox')"
  branch="$(state_value "$id" '.branch')"
  repo_dir="$(state_value "$id" '.repoDir')"
  repo_path="$(canonical_repo "$(state_value "$id" '.repo')")"

  [[ "$(git -C "$repo_path" rev-parse --verify "$commit^{commit}")" == "$commit" ]] ||
    die "sync source is not an available commit"
  [[ -z "$(sbx_call "$sbx" exec "$sandbox" -- git -C "$repo_dir" status --porcelain)" ]] ||
    die "sandbox repository has uncommitted changes"
  [[ "$(sbx_call "$sbx" exec "$sandbox" -- git -C "$repo_dir" branch --show-current)" == "$branch" ]] ||
    die "sandbox repository is not on the expected branch"

  local vm_bundle="/tmp/sbx-work-${id}-sync-${BASHPID}.bundle"
  local sync_ref="refs/sbx-work/transfers/$id/$BASHPID"
  local bundle="${state_root}/${id}-sync.bundle"
  if ! $dry_run; then
    bundle="$(mktemp "${state_root}/${id}-sync.XXXXXX.bundle")"
    trap 'rm -f -- "$bundle"; git -C "$repo_path" update-ref -d "$sync_ref" "$commit"; sbx_call "$sbx" exec "$sandbox" -- rm -f -- "$vm_bundle" >/dev/null 2>&1 || true' EXIT
  fi
  # A self-contained bundle also works with shallow or disconnected VM history.
  run git -C "$repo_path" update-ref "$sync_ref" "$commit" ""
  run git -C "$repo_path" bundle create "$bundle" "$sync_ref"
  run git -C "$repo_path" bundle verify "$bundle"
  if ! $dry_run; then
    [[ "$(git -C "$repo_path" bundle list-heads "$bundle" "$sync_ref")" == "$commit $sync_ref" ]] ||
      die "bundle does not match the requested commit"
  fi
  run sbx_copy_to "$sbx" "$sandbox" "$bundle" "$vm_bundle"
  run sbx_call "$sbx" exec "$sandbox" -- git -C "$repo_dir" bundle verify "$vm_bundle"
  sbx_exec_shell "$sbx" "$sandbox" \
    "cd $(printf '%q' "$repo_dir") && git fetch $(printf '%q' "$vm_bundle") $(printf '%q' "$sync_ref") && git reset --hard $(printf '%q' "$commit")"

  if ! $dry_run; then
    [[ "$(sbx_call "$sbx" exec "$sandbox" -- git -C "$repo_dir" rev-parse HEAD)" == "$commit" ]] ||
      die "synchronized VM HEAD does not match the requested commit"
    update_state "$id" '.syncedCommit = $commit' --arg commit "$commit"
  fi
  note "synced $commit; run repository validation inside the VM"
)
