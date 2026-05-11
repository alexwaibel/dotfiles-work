---
name: status
description: Check current item status, update local state, detect items needing review, and check the browser queue. Use when the user says "status", "check progress", or "what's running".
allowed-tools: shell
---

# Status

Check current items, update state, report progress.

> **Note — Copilot CLI migration:** the original Claude Code version of this
> skill polled background subagent tasks (via `TaskList`) to detect agents that
> had completed, gone missing, or got stuck. Copilot CLI is a single-agent CLI
> with no subagent system, so this skill now just inspects local repo state
> (branches, PRs) and the browser queue. If/when a Copilot equivalent for
> background agents exists, restore the agent-task polling here.

## Procedure

1. Read state file (`~/cockpit/state/ado-tasks.md`)
2. For each `in-progress` item, check the recorded branch:
   - Branch missing locally and remotely -> mark `blocked` with note "branch lost"
   - Branch has commits ahead of base -> show latest commit; suggest `done-needs-review` if a PR is open
   - No commits yet -> still `in-progress`
3. Check for PRs on branches without a PR recorded (`az repos pr list` filtered by source ref)
4. **Check browser queue** (`~/cockpit/state/browser-queue/`):
   - `.request.md` without matching `.response.md` -> pending browser task, remind user
   - `.response.md` exists -> note in state for follow-up
5. Write updated state file
6. Report: in-progress, completed, blocked, browser-tasks-pending, needs-human-attention
