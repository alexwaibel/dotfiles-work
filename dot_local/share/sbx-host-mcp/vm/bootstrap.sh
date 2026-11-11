#!/usr/bin/env bash
set -euo pipefail

repo="$1"
branch="$2"
base="$3"
git_name="$4"
git_email="$5"
reuse="$6"

if [[ "$reuse" == true ]]; then
  git -C "$repo" checkout -B "$branch" "$base"
else
  git -C "$repo" checkout -b "$branch" "$base"
fi
git -C "$repo" config user.name "$git_name"
git -C "$repo" config user.email "$git_email"

if command -v corepack >/dev/null 2>&1; then
  mkdir -p "$HOME/.local/bin"
  corepack enable --install-directory "$HOME/.local/bin" ||
    echo "warning: corepack shims unavailable" >&2
  rm -f "$HOME/.local/bin/yarn"
  cat >"$HOME/.local/bin/yarn" <<'EOF'
#!/usr/bin/env bash
dir="$PWD"
while [[ "$dir" != / ]]; do
  yarn_path="$(sed -n "s/^yarnPath:[[:space:]]*//p" "$dir/.yarnrc.yml" 2>/dev/null | head -n1)"
  yarn_path="${yarn_path#\"}"
  yarn_path="${yarn_path%\"}"
  if [[ -n "$yarn_path" ]]; then
    [[ "$yarn_path" = /* ]] || yarn_path="$dir/$yarn_path"
    [[ -f "$yarn_path" ]] && exec node "$yarn_path" "$@"
  fi
  dir="${dir%/*}"
  [[ -n "$dir" ]] || dir=/
done
exec corepack yarn "$@"
EOF
  chmod u+x "$HOME/.local/bin/yarn"
fi
