---
name: status
description: Check live work-item, branch, PR, sandbox, and recent-session status. Use when the user says "status", "check progress", or "what's running".
---

# Status

Check live systems and report progress without maintaining a local state mirror.

## Procedure

1. Fetch current-sprint items assigned to the user from ADO.
2. List registered Git worktrees under `~/repos/worktrees`.
3. Match agent branches (`{{ .ado.branchPrefix }}*`) to open draft PRs.
4. Query recent Copilot session history for matching work-item, branch, PR, and
   commit references.
5. Inspect `~/.local/state/sbx-work/*.json` and correlate it with live Docker
   sandboxes when sandbox work is present.
6. Report:
   - active work items with branch/PR/session evidence
   - branches with no recent session or PR
   - stopped/running sandboxes and unexported work
   - items awaiting review or human input

Do not write a status file. ADO, Git, Docker, and session history remain the
authoritative sources.
