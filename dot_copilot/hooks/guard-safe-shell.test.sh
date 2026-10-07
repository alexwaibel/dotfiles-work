#!/usr/bin/env bash

set -uo pipefail

HOOK="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/guard-safe-shell.sh"
PASS=0
FAIL=0

payload() {
  local cmd="$1" format="${2:-object}"
  if [[ "$format" == "string" ]]; then
    jq -nc --arg cmd "$cmd" '
      {
        timestamp: 0,
        cwd: "/tmp",
        toolName: "bash",
        toolArgs: ({command: $cmd} | tostring)
      }
    '
    return
  fi

  jq -nc --arg cmd "$cmd" '
    {
      timestamp: 0,
      cwd: "/tmp",
      toolName: "bash",
      toolArgs: {command: $cmd}
    }
  '
}

expect_allow() {
  local desc="$1" cmd="$2"
  local output exit_code
  output=$(payload "$cmd" | bash "$HOOK" 2>&1) && exit_code=0 || exit_code=$?
  if [[ $exit_code -eq 0 ]] && [[ "$output" != *'"deny"'* ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (exit=$exit_code output='$output')"
    FAIL=$((FAIL + 1))
  fi
}

expect_block() {
  local desc="$1" cmd="$2"
  local output exit_code
  output=$(payload "$cmd" | bash "$HOOK" 2>&1) && exit_code=0 || exit_code=$?
  if [[ "$output" == *'"deny"'* ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (exit=$exit_code output='$output')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Allowed commands ==="
expect_allow "rg with no config" "rg --no-config pattern ."
expect_allow "read-only sort" "sort input.txt"
expect_allow "read-only find" "find . -name '*.sh'"
expect_allow "unrelated command" "git status"

echo ""
echo "=== Blocked commands ==="
expect_block "rg without no config" "rg pattern ."
expect_block "rg preprocessor" "rg --no-config --pre cat pattern ."
expect_block "sort output file" "sort -o output.txt input.txt"
expect_block "find delete" "find . -delete"
expect_block "command chaining" "rg --no-config pattern . | cat"

echo ""
echo "=== Payload compatibility ==="
output=$(payload "rg pattern ." string | bash "$HOOK" 2>&1)
if [[ "$output" == *'"deny"'* ]]; then
  echo "  PASS: legacy JSON-string toolArgs"
  PASS=$((PASS + 1))
else
  echo "  FAIL: legacy JSON-string toolArgs (output='$output')"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
