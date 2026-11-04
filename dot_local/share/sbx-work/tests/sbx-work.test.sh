#!/usr/bin/env bash

set -euo pipefail

script="${1:-${HOME}/.local/bin/sbx-work}"
pass=0
fail=0

expect_success() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS: %s\n' "$description"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s\n' "$description"
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

expect_success "shell syntax" bash -n "$script"
expect_success "help" bash "$script" --help
expect_failure "missing command" bash "$script"
expect_failure "unknown command" bash "$script" unknown
expect_failure "invalid seed work item" bash "$script" --dry-run seed abc valid-slug repo
expect_failure "invalid slug" bash "$script" --dry-run seed 123 Invalid_Slug repo

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

repos_root="${tmp_dir}/repos"
state_root="${tmp_dir}/state"
repo="${repos_root}/example-repo"
remote="${tmp_dir}/remote.git"
mkdir -p "$repo"
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

dry_run_output="$(
  SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN=/bin/true \
  bash "$script" --dry-run seed 123 valid-slug example-repo
)"
if [[ "$dry_run_output" == *"create --name wi-123-vm copilot"* ]] &&
  [[ "$dry_run_output" == *"wi-123-vm:/tmp/example-repo.bundle"* ]] &&
  [[ "$dry_run_output" == *"users/alwaibel/agent/123-valid-slug"* ]] &&
  [[ ! -e "${state_root}/123.json" ]]; then
  printf 'PASS: seed dry-run plan\n'
  pass=$((pass + 1))
else
  printf 'FAIL: seed dry-run plan\n'
  fail=$((fail + 1))
fi

mkdir -p "$state_root"
cat >"${state_root}/123.json" <<'EOF'
{
  "workItem": "123",
  "repo": "example-repo",
  "sandbox": "wi-123-vm",
  "repoDir": "/home/agent/workspace/example-repo"
}
EOF

git -C "$repo" remote set-url origin \
  https://example.visualstudio.com/DefaultCollection/Project/_git/example-repo
ado_install_output="$(
  SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN=/bin/true \
    bash "$script" --dry-run ado-install 123 -- yarn install --immutable
)"
if [[ "$ado_install_output" == *"ADO_NPM_TOKEN=<redacted>"* ]] &&
  [[ "$ado_install_output" == *"YARN_ENABLE_SCRIPTS=false"* ]] &&
  [[ "$ado_install_output" == *"yarn install --immutable"* ]]; then
  printf 'PASS: ado-install dry-run plan\n'
  pass=$((pass + 1))
else
  printf 'FAIL: ado-install dry-run plan\n'
  fail=$((fail + 1))
fi

expect_failure "reject arbitrary token command" \
  env \
  SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN=/bin/true \
  bash "$script" --dry-run ado-install 123 -- env

expect_failure "reject package lifecycle override" \
  env \
  SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN=/bin/true \
  bash "$script" --dry-run ado-install 123 -- npm install --ignore-scripts=false

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
