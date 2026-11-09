# shellcheck shell=bash
# shellcheck disable=SC2034

set -euo pipefail

script="${1:-${HOME}/.local/bin/sbx-work}"
pass=0
fail=0

expect_success() {
  local description="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    printf 'PASS: %s\n' "$description"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s\n' "$description"
    printf '%s\n' "$output"
    fail=$((fail + 1))
  fi
}

expect_failure() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s\n' "$description"
    fail=$((fail + 1))
  else
    printf 'PASS: %s\n' "$description"
    pass=$((pass + 1))
  fi
}

record_pass() {
  printf 'PASS: %s\n' "$1"
  pass=$((pass + 1))
}

record_fail() {
  printf 'FAIL: %s\n' "$1"
  fail=$((fail + 1))
}

setup_fixture() {
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  repos_root="${tmp_dir}/repos"
  state_root="${tmp_dir}/state"
  repo="${repos_root}/example-repo"
  remote="${tmp_dir}/remote.git"
  mkdir -p "$repo" "$state_root"
  git init -q --bare "$remote"
  git -C "$repo" init -q -b master
  git -C "$repo" config user.name "Test User"
  git -C "$repo" config user.email "test@example.com"
  printf 'test\n' >"${repo}/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm "Initial commit"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -qu origin master
  git --git-dir="$remote" symbolic-ref HEAD refs/heads/master
  git -C "$repo" remote set-head origin --auto >/dev/null

  fake_sbx="${tmp_dir}/fake-sbx"
  fake_sbx_log="${tmp_dir}/fake-sbx.log"
  cat >"$fake_sbx" <<EOF
#!/usr/bin/env bash
command="\$1"
shift
[[ "\${1:-}" == "--no-input" ]] && shift
set -- "\$command" "\$@"
printf '%s\n' "\$*" >>"$fake_sbx_log"
if [[ "\${1:-}" == "exec" ]]; then
  printf 'forwarded:%s:%s\n' "\${WSLENV:-}" "\${#ADO_NPM_TOKEN}" >>"$fake_sbx_log"
  [[ "\$*" == *"copilot --yolo"* ]] && printf 'agent completed task\n'
  [[ "\$*" == *"-- pwd" ]] && printf '/home/agent/workspace/example-repo\n'
fi
if [[ "\${1:-}" == "ls" ]]; then
  [[ -n "\${FAKE_SBX_LIST:-}" ]] && printf '%s\n' "\$FAKE_SBX_LIST"
  exit 0
fi
if [[ "\${FAKE_SBX_FAIL_EXEC:-false}" == "true" && "\${1:-}" == "exec" ]]; then
  exit 1
fi
EOF
  chmod u+x "$fake_sbx"
}

finish_tests() {
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  [[ "$fail" -eq 0 ]]
}
