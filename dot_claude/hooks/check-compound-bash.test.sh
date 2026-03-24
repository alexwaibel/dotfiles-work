#!/usr/bin/env bash
# Tests for check-compound-bash.sh hook
# Run: bash ~/.claude/hooks/check-compound-bash.test.sh

set -uo pipefail

HOOK="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/check-compound-bash.sh"
PASS=0
FAIL=0

make_input() {
  local cmd="$1"
  # Escape double quotes and backslashes for JSON
  cmd=$(echo "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')
  echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}"
}

expect_allow() {
  local desc="$1" cmd="$2"
  local output exit_code
  output=$(make_input "$cmd" | bash "$HOOK" 2>&1) && exit_code=0 || exit_code=$?
  if [[ $exit_code -eq 0 ]] && echo "$output" | grep -q '"permissionDecision":"allow"'; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected allow decision, got exit=$exit_code output='$output')"
    FAIL=$((FAIL + 1))
  fi
}

expect_passthrough() {
  local desc="$1" cmd="$2"
  local output exit_code
  output=$(make_input "$cmd" | bash "$HOOK" 2>&1) && exit_code=0 || exit_code=$?
  # Passthrough = exit 0 with no permissionDecision in output
  if [[ $exit_code -eq 0 ]] && ! echo "$output" | grep -q 'permissionDecision'; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected passthrough, got exit=$exit_code output='$output')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Simple commands (should pass through — not compound) ==="
expect_passthrough "single git command"       "git status"
expect_passthrough "single ls command"        "ls -la"
expect_passthrough "single yarn command"      "yarn install"

echo ""
echo "=== Compound commands — all parts allowed ==="
expect_allow "cd repo && git status"          "cd /home/alwaibel/teams-client-workflows && git status"
expect_allow "cd repo && git log"             "cd /home/alwaibel/teams-client-workflows && git log --oneline -5"
expect_allow "cd repo && git diff"            "cd /home/alwaibel/teams-client-workflows && git diff HEAD"
expect_allow "cd repo && git add && commit"   "cd /home/alwaibel/teams-client-workflows && git add -A && git commit -m \"test\""
expect_allow "git fetch && git log"           "git fetch origin && git log --oneline -5"
expect_allow "three allowed parts with ;"     "git status; git log --oneline; git diff"
expect_allow "mixed && and ||"                "git fetch origin && git status || git log"

echo ""
echo "=== Compound commands — some parts NOT allowed (should pass through) ==="
expect_passthrough "cd repo && unknown cmd"   "cd /home/alwaibel/teams-client-workflows && rm -rf /"
expect_passthrough "allowed && curl"          "git status && curl http://example.com"
expect_passthrough "allowed ; npm install"    "git status ; npm install malicious-pkg"
expect_passthrough "unknown first part"       "whoami && git status"

echo ""
echo "=== Dangerous patterns (should pass through to ask) ==="
expect_passthrough "subshell injection"       "cd /home/alwaibel/teams-client-workflows && git push \$(echo main)"
expect_passthrough "backtick injection"       "cd /home/alwaibel/teams-client-workflows && git push \`echo main\`"

echo ""
echo "=== Edge cases ==="
expect_passthrough "empty command"            ""
expect_passthrough "only whitespace"          "   "
expect_allow "extra whitespace around &&"     "  git status   &&   git log  "

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
