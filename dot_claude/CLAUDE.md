# Dotfiles / Chezmoi

My dotfiles are managed with [chezmoi](https://www.chezmoi.io/). The source repo is at `~/.local/share/chezmoi/`.

- When modifying config files that chezmoi manages (e.g. `~/.claude.json`, `~/.claude/settings.json`), always update the **chezmoi source** (the template/file under `~/.local/share/chezmoi/`) rather than editing the target file directly.
- After updating chezmoi source files, run `chezmoi apply --force` to apply changes.
- Files ending in `.tmpl` are Go templates — chezmoi renders them using data from `.chezmoidata.*` and `chezmoi.toml`.

# Code Quality

- **Verify types before proposing an approach.** Don't assume a property exists on a type — check the type definition first. This applies especially at system boundaries (e.g., Relay's `PayloadError` type doesn't expose `extensions` or `originalError` even though the runtime objects may have them).
- **Find existing patterns first.** Before designing new infrastructure (error handling, toasts, data plumbing), search for how the codebase already handles the analogous success case or similar scenarios. Match the existing pattern rather than inventing a new one.
- **Don't commit until the design is stable.** When a change touches multiple layers or involves uncertainty about how systems interact, work through the design questions before making incremental commits. Multiple design reversals create a messy git history and waste review effort.
- **Push back when uncertain.** If you're not sure how a system behaves at a boundary (e.g., "does this framework preserve this field?"), say so and propose verifying it before committing to an approach. Implementing speculatively and discovering problems is more expensive than investigating first.
