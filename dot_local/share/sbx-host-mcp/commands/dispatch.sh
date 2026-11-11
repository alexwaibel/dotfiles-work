# shellcheck shell=bash
# shellcheck disable=SC2016,SC2154

run_job() (
  local id="$1"
  local task_id="$2"
  validate_work_item "$id"
  validate_task_id "$task_id"

  local prompt_file log_file metadata_file
  prompt_file="$(task_prompt_file "$task_id")"
  log_file="$(task_log_file "$task_id")"
  metadata_file="$(task_file "$task_id")"
  [[ -f "$metadata_file" ]] ||
    die "task files are incomplete: $task_id"
  [[ "$(jq -r '.workItem' "$metadata_file")" == "$id" ]] ||
    die "task work item does not match"

  # shellcheck disable=SC2317
  complete_job() {
    local exit_code=$? status=failed
    [[ "$exit_code" -eq 0 ]] && status=completed
    update_task "$task_id" \
      'if .status == "canceled" or .cancelRequested then
         .status = "canceled" | .completedAt = $completed
       else
         .status = $status | .exitCode = $exitCode | .completedAt = $completed
       end' \
      --arg status "$status" --argjson exitCode "$exit_code" \
      --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    rm -f "$prompt_file"
  }
  trap 'complete_job' EXIT

  mkdir -p "$tasks_root"
  exec 8>"${state_root}/task-${id}.lock"
  if ! flock -n 8; then
    update_task "$task_id" \
      '.status = "failed" | .error = "another task is active for this work item"'
    die "another task is active for work item $id"
  fi

  update_task "$task_id" \
    'if .cancelRequested or .status == "canceled" then
       .status = "canceled"
     else
       .status = "running" | .runnerPid = $pid | .startedAt = $started
     end' \
    --argjson pid "$$" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$(jq -r '.status' "$metadata_file")" == "canceled" ]]; then
    rm -f "$prompt_file"
    return 130
  fi

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
      [[ -f "$prompt_file" ]] || die "task prompt is missing"
      local sbx sandbox repo_dir
      sbx="$(find_sbx)"
      sandbox="$(state_value "$id" '.sandbox')"
      repo_dir="$(state_value "$id" '.repoDir')"
      sbx_call "$sbx" exec -i -w "$repo_dir" "$sandbox" -- \
        bash -lc 'prompt="$(cat)"; export PATH="$HOME/.local/bin:$PATH"; exec copilot --yolo -p "$prompt"' \
        <"$prompt_file" >"$log_file" 2>&1
      ;;
    *)
      die "unsupported job kind"
      ;;
  esac
)
