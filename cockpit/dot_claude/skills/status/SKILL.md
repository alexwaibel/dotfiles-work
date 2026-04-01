---
name: status
description: Check in-flight agent tasks, update local state, detect completed/blocked/lost agents, check browser queue, and report progress. Use when the user says "status", "how are agents doing", "check progress", or "what's running".
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
  - TaskList
  - TaskGet
  - mcp__azure-devops__wit_get_work_item
---

# Status

Check in-flight agents, update state, report progress.

## Procedure

1. Read state file (`~/cockpit/state/ado-tasks.md`)
2. Check in-session tasks via TaskList:
   - Completed -> update state to `done`
   - Still running -> report as in-progress
   - Missing (session restart) -> check for branch in repo (`git branch -r`); if found with commits -> `done-needs-review`, else -> `blocked` ("agent session lost")
3. Check for PRs on branches without a PR recorded
4. **Check browser queue** (`~/cockpit/state/browser-queue/`):
   - `.request.md` without matching `.response.md` -> pending browser task, remind user
   - `.response.md` exists -> feed findings back to the relevant work item's agent (resume or note in state)
5. Write updated state file
6. Report: in-progress, completed, blocked, browser-tasks-pending, needs-human-attention
