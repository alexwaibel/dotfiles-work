#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal shell snippets are appended to .bashrc.
# First-time WSL/Linux user configuration. Runs after managed files are applied.

set -euo pipefail

if ! grep -q 'starship init bash' "$HOME/.bashrc" 2>/dev/null; then
    echo 'eval "$(starship init bash)"' >>"$HOME/.bashrc"
fi

echo "Checking Bitwarden status ..."
bw_status="$(bw status 2>/dev/null | jq -r '.status' || echo not-installed)"
if [ "$bw_status" = "unauthenticated" ]; then
    bw login
elif [ "$bw_status" = "locked" ]; then
    export BW_SESSION
    BW_SESSION="$(bw unlock --raw)"
fi

mkdir -p "$HOME/.ssh"
if [ -f "$HOME/.ssh/agent-bridge.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOME/.ssh/agent-bridge.sh"
fi

if ! grep -q 'agent-bridge.sh' "$HOME/.bashrc" 2>/dev/null; then
    echo 'source "$HOME/.ssh/agent-bridge.sh"' >>"$HOME/.bashrc"
fi

pubkey="$(ssh-add -L 2>/dev/null | grep alexwaibelmsft || true)"
if [ -n "$pubkey" ]; then
    printf '%s\n' "$pubkey" >"$HOME/.ssh/alexwaibelmsft.pub"
    chmod 600 "$HOME/.ssh/alexwaibelmsft.pub"
    git -C "$HOME/.local/share/chezmoi" remote set-url origin \
        git@github.com:alexwaibel/dotfiles-work.git
else
    echo "WARNING: Could not find alexwaibelmsft key in SSH agent." >&2
fi

win_npmrc="/mnt/c/Users/$(whoami)/.npmrc"
if [ -f "$win_npmrc" ]; then
    ln -sf "$win_npmrc" "$HOME/.npmrc"
else
    echo "WARNING: Windows .npmrc not found at $win_npmrc." >&2
fi

echo "Linux user configuration ready."
