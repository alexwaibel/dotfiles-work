#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

source "$(dirname "${BASH_SOURCE[0]}")/shell-test-helpers.sh"
setup_fixture

dry_run_output="$(
  SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN=/bin/true \
  bash "$script" --dry-run seed 123 valid-slug example-repo
)"
if [[ "$dry_run_output" == *"create --clone --name wi-123-vm --static-mcp none --skills off copilot"* ]] &&
  [[ "$dry_run_output" != *"example-repo.bundle"* ]] &&
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
SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN="$fake_sbx" \
  bash "$script" seed 125 fresh-seed example-repo >/dev/null
if [[ "$(jq -r '.slug' "${state_root}/125.json")" == "fresh-seed" ]] &&
  grep -q '^create --clone --name wi-125-vm --static-mcp none --skills off copilot ' "$fake_sbx_log"; then
  printf 'PASS: replace stale unexported metadata\n'
  pass=$((pass + 1))
else
  printf 'FAIL: replace stale unexported metadata\n'
  fail=$((fail + 1))
fi

inspect_present_output="$(
  FAKE_SBX_LIST=wi-125-vm \
    SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN="$fake_sbx" \
    bash "$script" inspect 125
)"
if [[ "$(jq -r '.sandboxStatus' <<<"$inspect_present_output")" == "present" ]]; then
  printf 'PASS: inspect present sandbox\n'
  pass=$((pass + 1))
else
  printf 'FAIL: inspect present sandbox\n'
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

inspect_exported_output="$(
  SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN="$fake_sbx" \
    bash "$script" inspect 126
)"
if [[ "$(jq -r '.sandboxStatus' <<<"$inspect_exported_output")" == "missing-exported" ]]; then
  printf 'PASS: inspect missing exported sandbox\n'
  pass=$((pass + 1))
else
  printf 'FAIL: inspect missing exported sandbox\n'
  fail=$((fail + 1))
fi

cat >"${state_root}/128.json" <<'EOF'
{
  "workItem": "128",
  "repo": "example-repo",
  "sandbox": "wi-128-vm",
  "privateValue": "must-not-leak"
}
EOF
inspect_stale_output="$(
  SBX_WORK_REPOS_ROOT="$repos_root" \
    SBX_WORK_STATE_ROOT="$state_root" \
    SBX_WORK_SBX_BIN="$fake_sbx" \
    bash "$script" inspect 128
)"
if [[ "$(jq -r '.sandboxStatus' <<<"$inspect_stale_output")" == "missing-unexported" ]] &&
  [[ "$inspect_stale_output" != *"must-not-leak"* ]]; then
  printf 'PASS: inspect missing unexported sandbox\n'
  pass=$((pass + 1))
else
  printf 'FAIL: inspect missing unexported sandbox\n'
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
  [[ "$private_seed_output" == *"vsassets.io"* ]] &&
  [[ "$private_seed_output" == *"YARN_ENABLE_SCRIPTS=false"* ]] &&
  [[ ! -e "${state_root}/124.json" ]]; then
  printf 'PASS: private dependency seed preflight\n'
  pass=$((pass + 1))
else
  printf 'FAIL: private dependency seed preflight\n'
  fail=$((fail + 1))
fi

fake_powershell="${tmp_dir}/powershell.exe"
fake_powershell_log="${tmp_dir}/powershell.log"
cat >"$fake_powershell" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$fake_powershell_log"
printf 'package-read-token\\r\\n'
EOF
chmod u+x "$fake_powershell"
: >"$fake_sbx_log"
git -C "$repo" remote set-url origin "$remote"
SBX_WORK_REPOS_ROOT="$repos_root" \
  SBX_WORK_STATE_ROOT="$state_root" \
  SBX_WORK_SBX_BIN="$fake_sbx" \
  SBX_WORK_POWERSHELL_BIN="$fake_powershell" \
  SBX_WORK_ADO_ORGANIZATION=example \
  bash "$script" seed 129 windows-auth example-repo >/dev/null
if [[ -f "${state_root}/129.json" ]] &&
  grep -q 'azureauth ado pat' "$fake_powershell_log" &&
  grep -q -- '-e ADO_NPM_TOKEN' "$fake_sbx_log" &&
  grep -Eq '^forwarded:.*ADO_NPM_TOKEN:[1-9][0-9]*$' "$fake_sbx_log" &&
  grep -q 'node_modules/.yarn-state.yml' "$fake_sbx_log" &&
  ! grep -q 'package-read-token' "$fake_sbx_log"; then
  printf 'PASS: Windows auth token stays out of VM command arguments\n'
  pass=$((pass + 1))
else
  printf 'FAIL: Windows auth token stays out of VM command arguments\n'
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


finish_tests
