---
name: audit-mcp-tools
description: Audit configured MCP tool allowlists against the pinned inventory and live server surfaces. Use when reviewing MCP permissions, checking for newly added or removed MCP tools, or updating safe auto-approval classifications.
---

# Audit MCP Tools

Compares the chezmoi-managed MCP inventory with the rendered Copilot configuration and each
configured server's live `tools/list` response. The audit is read-only: report changes and risk
classifications, but do not update the inventory without explicit approval.

## When to use this skill

Use this skill when:

- Asked to audit, review, or refresh MCP tools
- An MCP package or launcher version changes
- A server exposes new tools or removes existing tools
- Reviewing which tools are safe to auto-approve

## How it works

1. Run the static audit first:

   ```bash
   python3 ~/.copilot/skills/audit-mcp-tools/scripts/audit.py --skip-live
   ```

2. Run the live audit:

   ```bash
   python3 ~/.copilot/skills/audit-mcp-tools/scripts/audit.py
   ```

   Limit investigation to selected servers when useful:

   ```bash
   python3 ~/.copilot/skills/audit-mcp-tools/scripts/audit.py \
     --server azure-devops \
     --server teams-chat
   ```

3. Report:
   - Live tools absent from the pinned configuration
   - Configured tools no longer offered by the server
   - Inventory/configuration mismatches
   - Tools available but intentionally excluded from safe auto-approval
   - Servers that could not be started or queried

4. If changes are needed, inspect each tool before classifying it:
   - `all`: every explicitly exposed tool
   - `safe`: read-oriented tools approved by the default `acp` profile
   - `highRisk`: tools needing a warning because they mutate external state, execute arbitrary
     code, upload data, or perform destructive operations

5. After explicit approval, update:

   ```text
   ~/.local/share/chezmoi/.chezmoidata/mcp-tools.json
   ```

   Run `chezmoi diff`, apply with `chezmoi apply --force`, and repeat both audits.

## Exit codes

- `0`: no inventory drift
- `1`: tool-surface drift or an MCP server error
- `2`: invalid or missing configuration

## Safety

- Do not automatically enable newly discovered tools.
- Do not classify mutation tools as safe solely because their names sound harmless.
- Treat browser input, uploads, arbitrary evaluation, messages, mail, incidents, pipelines,
  work items, ingestion, and management commands as external mutations.
- Distinguish availability from approval: `mcp-config.json` exposes pinned tools, while the
  `acp` launcher controls which tools run without confirmation.
