#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

source "$(dirname "${BASH_SOURCE[0]}")/shell-test-helpers.sh"
setup_fixture

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


finish_tests
