#!/usr/bin/env bash
# Ensure ~/.bashrc sources the chezmoi-managed WSL customization file.
# ~/.bashrc is distro-provided and intentionally left unmanaged by chezmoi
# (agency also appends to it), so the source hook is wired in idempotently
# here instead of managing ~/.bashrc directly.
set -eu

BASHRC="$HOME/.bashrc"
[ -f "$BASHRC" ] || exit 0
grep -q "bashrc_wsl_customization" "$BASHRC" && exit 0

cat >> "$BASHRC" <<'HOOK'

# BEGIN WSL customization block
if [ -f ~/.bashrc_wsl_customization ]; then
    . ~/.bashrc_wsl_customization
fi
# END WSL customization block
HOOK
echo "Wired ~/.bashrc to source ~/.bashrc_wsl_customization"
