#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cd "$repo_root"

section() {
  printf '\n== %s ==\n' "$1"
}

section "Git diff"
git diff --check

section "JSON"
while IFS= read -r file; do
  jq -e . "$file" >/dev/null
done < <(
  git ls-files \
    '.chezmoidata/*.json' \
    'dot_copilot/private_permissions-config.json' \
    'dot_local/share/**/package.json' \
    'dot_local/share/**/package-lock.json'
)

section "Shell sources"
mapfile -t candidate_sources < <(
  find . -path './.git' -prune -o -type f \
    \( -name '*.sh' -o -path './dot_local/bin/executable_*' \) \
    ! -name '*.tmpl' -print |
    sed 's#^\./##' |
    sort
)
for source in "${candidate_sources[@]}"; do
  first_line="$(head -n 1 "$source")"
  if [[ "$source" == *.sh || "$first_line" =~ ^\#\!.*(ba|z|k)?sh ]]; then
    shellcheck -s bash "$source"
  fi
done

section "Rendered shell templates"
mapfile -t shell_templates < <(
  find . -path './.git' -prune -o -type f -name '*.sh.tmpl' -print |
    sed 's#^\./##' |
    sort
)
for source in "${shell_templates[@]}"; do
  rendered="${tmp_dir}/$(basename "${source%.tmpl}")"
  chezmoi execute-template <"$source" >"$rendered"
  bash -n "$rendered"
  shellcheck -e SC2016 "$rendered"
done

section "PowerShell sources"
while IFS= read -r source; do
  rendered="${tmp_dir}/$(basename "${source%.tmpl}")"
  if [[ "$source" == *.tmpl ]]; then
    chezmoi execute-template <"$source" >"$rendered"
  else
    cp "$source" "$rendered"
  fi
  windows_path="$(wslpath -w "$rendered")"
  powershell.exe -NoProfile -Command \
    "\$errors = \$null; [System.Management.Automation.Language.Parser]::ParseFile('$windows_path', [ref]\$null, [ref]\$errors) > \$null; if (\$errors.Count) { \$errors | ForEach-Object { Write-Error \$_ }; exit 1 }"
done < <(
  find . -path './.git' -prune -o -type f \
    \( -name '*.ps1' -o -name '*.ps1.tmpl' \) -print |
    sed 's#^\./##' |
    sort
)

section "Rendered JSON templates"
chezmoi execute-template <dot_copilot/mcp-config.json.tmpl \
  >"${tmp_dir}/mcp-config.json"
chezmoi execute-template <dot_config/acp/mcp-tools.json.tmpl \
  >"${tmp_dir}/mcp-tools.json"
jq -e . "${tmp_dir}/mcp-config.json" >/dev/null
jq -e . "${tmp_dir}/mcp-tools.json" >/dev/null

section "MCP inventory"
python3 dot_copilot/skills/audit-mcp-tools/scripts/audit.py \
  --config "${tmp_dir}/mcp-config.json" \
  --manifest "${tmp_dir}/mcp-tools.json" \
  --skip-live

section "Copilot configuration"
node --test tests/acp.test.mjs tests/copilot-profile.test.mjs

section "Copilot hooks"
bash dot_copilot/hooks/guard-safe-shell.test.sh

for package in sbx-host-mcp host-attachments-mcp; do
  section "${package}"
  cp -a "dot_local/share/${package}" "${tmp_dir}/${package}"
  npm ci \
    --prefix "${tmp_dir}/${package}" \
    --ignore-scripts \
    --no-audit \
    --no-fund \
    --registry=https://registry.npmjs.org
  npm test --prefix "${tmp_dir}/${package}"
  npm audit \
    --omit=dev \
    --audit-level=high \
    --registry=https://registry.npmjs.org \
    --prefix "${tmp_dir}/${package}"
done

printf '\nAll dotfiles checks passed.\n'
