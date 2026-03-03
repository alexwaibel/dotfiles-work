# Dotfiles / Chezmoi

My dotfiles are managed with [chezmoi](https://www.chezmoi.io/). The source repo is at `~/.local/share/chezmoi/`.

- When modifying config files that chezmoi manages (e.g. `~/.claude.json`, `~/.claude/settings.json`), always update the **chezmoi source** (the template/file under `~/.local/share/chezmoi/`) rather than editing the target file directly.
- After updating chezmoi source files, run `chezmoi apply --force` to apply changes.
- Files ending in `.tmpl` are Go templates — chezmoi renders them using data from `.chezmoidata.*` and `chezmoi.toml`.
