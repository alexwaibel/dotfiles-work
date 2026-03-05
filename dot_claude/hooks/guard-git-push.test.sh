#!/usr/bin/env bash
# Tests for guard-git-push.sh hook
# Run: bash ~/.claude/hooks/guard-git-push.test.sh

set -uo pipefail

HOOK="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/guard-git-push.sh"
PASS=0
FAIL=0

expect_allow() {
  local desc="$1" cmd="$2"
  local output exit_code
  output=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}" | bash "$HOOK" 2>&1) && exit_code=0 || exit_code=$?
  if [[ $exit_code -eq 0 ]] && [[ "$output" != BLOCK* ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected allow, got exit=$exit_code output='$output')"
    FAIL=$((FAIL + 1))
  fi
}

expect_block() {
  local desc="$1" cmd="$2"
  local output exit_code
  output=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}" | bash "$HOOK" 2>&1) && exit_code=0 || exit_code=$?
  if [[ $exit_code -ne 0 ]] || [[ "$output" == BLOCK* ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected block, got exit=$exit_code output='$output')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Allowed pushes ==="
expect_allow "valid branch"               "git push origin alwaibel/claude/123-test"
expect_allow "with -u flag"               "git push -u origin alwaibel/claude/456-feat"
expect_allow "with --force flag"          "git push --force origin alwaibel/claude/789-fix"
expect_allow "valid refspec"              "git push origin alwaibel/claude/1-a:alwaibel/claude/1-a"
expect_allow "multiple valid branches"    "git push origin alwaibel/claude/1-a alwaibel/claude/2-b"

echo ""
echo "=== Blocked pushes ==="
expect_block "push to main"              "git push origin main"
expect_block "push to master"            "git push origin master"
expect_block "push to develop"           "git push origin develop"
expect_block "push to feature branch"    "git push origin feature/something"
expect_block "refspec to main"           "git push origin alwaibel/claude/123-test:main"
expect_block "refspec to master"         "git push origin HEAD:master"
expect_block "bare push"                 "git push"
expect_block "push with only remote"     "git push origin"
expect_block "chain with &&"            "git push origin alwaibel/claude/1-a && git push origin main"
expect_block "chain with ;"             "git push origin alwaibel/claude/1-a ; git push origin main"
expect_block "chain with ||"            "git push origin alwaibel/claude/1-a || git push origin main"
expect_block "pipe"                      "git push origin alwaibel/claude/1-a | cat"
expect_block "subshell"                  "git push origin \$(echo main)"
expect_block "backticks"                 "git push origin \`echo main\`"
expect_block "one valid one bad"         "git push origin alwaibel/claude/1-a main"

echo ""
echo "=== Non-push commands (should pass through) ==="
expect_allow "ls"                        "ls -la"
expect_allow "git status"                "git status"
expect_allow "git pull"                  "git pull origin main"
expect_allow "non-Bash tool"             "echo hello"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
