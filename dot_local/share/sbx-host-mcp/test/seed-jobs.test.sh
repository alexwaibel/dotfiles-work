#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

source "$(dirname "${BASH_SOURCE[0]}")/shell-test-helpers.sh"
setup_fixture
mkdir -p "$state_root/tasks"

seed_job() {
  local id="$1" task_id="$2"
  jq -n --argjson workItem "$id" --arg taskId "$task_id" \
    '{taskId: $taskId, workItem: $workItem, kind: "seed", status: "queued",
      seed: {slug: "durable-seed", repo: "example-repo", reuseExistingBranch: false}}' \
    >"$state_root/tasks/$task_id.json"
  SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN="$fake_sbx" \
    bash "$script" run-job "$id" "$task_id"
}

task_id="task-11111111-1111-1111-1111-111111111111"
expect_success "shared job runner completes a seed" seed_job 151 "$task_id"
if jq -e '.status == "completed" and .exitCode == 0 and .completedAt != null' \
  "$state_root/tasks/$task_id.json" >/dev/null &&
  [[ -f "$state_root/151.json" ]]; then
  record_pass "seed completion is persisted with transfer metadata"
else
  record_fail "seed completion is persisted with transfer metadata"
fi

failed_id="task-22222222-2222-2222-2222-222222222222"
if FAKE_SBX_FAIL_EXEC=true seed_job 152 "$failed_id" >/dev/null 2>&1; then
  record_fail "shared runner reports failed seed"
else
  record_pass "shared runner reports failed seed"
fi
if jq -e '.status == "failed" and .exitCode != 0 and .completedAt != null' \
  "$state_root/tasks/$failed_id.json" >/dev/null &&
  [[ ! -f "$state_root/152.json" ]] &&
  grep -q '^rm --force wi-152-vm$' "$fake_sbx_log"; then
  record_pass "seed failure records terminal status and preserves atomic cleanup"
else
  record_fail "seed failure records terminal status and preserves atomic cleanup"
fi

finish_tests
