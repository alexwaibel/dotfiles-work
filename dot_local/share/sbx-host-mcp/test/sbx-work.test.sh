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
  [[ "$dry_run_output" != *"ADO_NPM_TOKEN"* ]] &&
  [[ ! -e "${state_root}/123.json" ]]; then
  printf 'PASS: seed dry-run plan\n'
  pass=$((pass + 1))
else
  printf 'FAIL: seed dry-run plan\n'
  fail=$((fail + 1))
fi

mkdir -p "$state_root"
cat >"${state_root}/125.json" <<'EOF'
{
  "workItem": "125",
  "repo": "example-repo",
  "sandbox": "wi-125-vm"
}
EOF
fake_sbx="${tmp_dir}/fake-sbx"
fake_sbx_log="${tmp_dir}/fake-sbx.log"
cat >"$fake_sbx" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$fake_sbx_log"
if [[ "\${1:-}" == "ls" ]]; then
  exit 0
fi
if [[ "\${FAKE_SBX_FAIL_EXEC:-false}" == "true" && "\${1:-}" == "exec" ]]; then
  exit 1
fi
EOF
chmod u+x "$fake_sbx"
SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN="$fake_sbx" \
  bash "$script" seed 125 fresh-seed example-repo >/dev/null
if [[ "$(jq -r '.slug' "${state_root}/125.json")" == "fresh-seed" ]] &&
  grep -q '^create --name wi-125-vm copilot$' "$fake_sbx_log"; then
  printf 'PASS: replace stale unexported metadata\n'
  pass=$((pass + 1))
else
  printf 'FAIL: replace stale unexported metadata\n'
  fail=$((fail + 1))
fi

cat >"${state_root}/126.json" <<'EOF'
{
  "workItem": "126",
  "repo": "example-repo",
  "sandbox": "wi-126-vm",
  "hostWorktree": "/tmp/preserved-worktree"
}
EOF
expect_failure "preserve stale exported metadata" \
  env \
  SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN="$fake_sbx" \
  bash "$script" seed 126 preserved-work example-repo
if [[ -f "${state_root}/126.json" ]]; then
  printf 'PASS: stale exported metadata remains\n'
  pass=$((pass + 1))
else
  printf 'FAIL: stale exported metadata remains\n'
  fail=$((fail + 1))
fi

: >"$fake_sbx_log"
expect_failure "clean failed seed" \
  env \
  FAKE_SBX_FAIL_EXEC=true \
  SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN="$fake_sbx" \
  bash "$script" seed 127 failed-seed example-repo
if [[ ! -e "${state_root}/127.json" ]] &&
  grep -q '^rm --force wi-127-vm$' "$fake_sbx_log"; then
  printf 'PASS: failed seed removes sandbox and metadata\n'
  pass=$((pass + 1))
else
  printf 'FAIL: failed seed removes sandbox and metadata\n'
  fail=$((fail + 1))
fi

cat >"${repo}/package.json" <<'EOF'
{
  "packageManager": "yarn@4.14.0"
}
EOF
cat >"${repo}/.yarnrc.yml" <<'EOF'
npmScopes:
  private:
    npmRegistryServer: "https://pkgs.dev.azure.com/example/project/_packaging/feed/npm/registry/"
    npmAuthToken: "${ADO_NPM_TOKEN}"
EOF
printf '__metadata:\n  version: 8\n' >"${repo}/yarn.lock"
git -C "$repo" add package.json .yarnrc.yml yarn.lock
git -C "$repo" commit -qm "Add private package metadata"
git -C "$repo" remote set-url origin \
  https://example.visualstudio.com/DefaultCollection/Project/_git/example-repo

private_seed_output="$(
  SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN=/bin/true \
    bash "$script" --dry-run seed 124 private-restore example-repo
)"
if [[ "$private_seed_output" == *"restoring private dependencies before agent startup"* ]] &&
  [[ "$private_seed_output" == *"ADO_NPM_TOKEN=<redacted>"* ]] &&
  [[ "$private_seed_output" == *"yarn install --immutable"* ]] &&
  [[ "$private_seed_output" == *"YARN_ENABLE_SCRIPTS=false"* ]] &&
  [[ ! -e "${state_root}/124.json" ]]; then
  printf 'PASS: private dependency seed preflight\n'
  pass=$((pass + 1))
else
  printf 'FAIL: private dependency seed preflight\n'
  fail=$((fail + 1))
fi

exec 8>"${state_root}/operation.lock"
flock -n 8
expect_failure "reject concurrent operation" \
  env \
  SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN=/bin/true \
  bash "$script" --dry-run seed 124 another-slug example-repo
flock -u 8

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
