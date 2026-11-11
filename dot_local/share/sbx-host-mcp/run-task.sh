#!/usr/bin/env bash
# shellcheck disable=SC1091
# shellcheck disable=SC2016,SC2154

set -euo pipefail

PROGRAM="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repos_root="${SBX_WORK_REPOS_ROOT:-${HOME}/repos}"
state_root="${SBX_WORK_STATE_ROOT:-${XDG_STATE_HOME:-${HOME}/.local/state}/sbx-work}"
tasks_root="${SBX_WORK_TASKS_ROOT:-${state_root}/tasks}"
dry_run=false

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/sbx-adapter.sh"
source "$SCRIPT_DIR/lib/package-auth.sh"
source "$SCRIPT_DIR/commands/seed.sh"

(($# == 2)) || die "private runner requires WORK_ITEM TASK_ID"
id="$1"
task_id="$2"
validate_work_item "$id"
validate_task_id "$task_id"

request="$(cat)"
log_file="${tasks_root}/${task_id}.log"
metadata_file="${tasks_root}/${task_id}.json"
canceled=false
mkdir -p "$tasks_root"
umask 077
jq -e --arg id "$id" --arg taskId "$task_id" --argjson pid "$$" \
  --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  'select((.workItem | tostring) == $id and .taskId == $taskId) |
   del(.prompt) | .status = "running" | .runnerPid = $pid | .startedAt = $started' \
  <<<"$request" >"${metadata_file}.tmp"
mv "${metadata_file}.tmp" "$metadata_file"

# shellcheck disable=SC2317
complete_job() {
  local exit_code=$? status=failed
  [[ "$exit_code" -eq 0 ]] && status=completed
  $canceled && status=canceled
  jq '.status = $status | .exitCode = $exitCode | .completedAt = $completed' \
    --arg status "$status" --argjson exitCode "$exit_code" \
    --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$metadata_file" >"${metadata_file}.tmp"
  mv "${metadata_file}.tmp" "$metadata_file"
}
trap 'complete_job' EXIT
trap 'canceled=true; exit 130' TERM INT

exec 8>"${state_root}/task-${id}.lock"
flock -n 8 || die "another task is active for work item $id"
jq -c . "$metadata_file"

case "$(jq -r '.kind // "copilot"' "$metadata_file")" in
  seed)
    {
      acquire_lock
      seed "$id" \
        "$(jq -er '.seed.slug' "$metadata_file")" \
        "$(jq -er '.seed.repo' "$metadata_file")" \
        "$(jq -r '.seed.reuseExistingBranch' "$metadata_file")"
    } >"$log_file" 2>&1
    ;;
  copilot)
    sbx="$(find_sbx)"
    sandbox="$(state_value "$id" '.sandbox')"
    repo_dir="$(state_value "$id" '.repoDir')"
    jq -er '.prompt | select(type == "string" and length > 0)' <<<"$request" |
      sbx_call "$sbx" exec -i -w "$repo_dir" "$sandbox" -- \
      bash -lc 'prompt="$(cat)"; export PATH="$HOME/.local/bin:$PATH"; exec copilot --yolo -p "$prompt"' \
      >"$log_file" 2>&1
    ;;
  *)
    die "unsupported job kind"
    ;;
esac
