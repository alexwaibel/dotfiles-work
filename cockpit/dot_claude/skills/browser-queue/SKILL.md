---
name: browser-queue
description: List and manage pending browser tasks in the WSL-to-Windows handoff queue. Use when the user says "browser queue", "pending browser tasks", "check browser requests", or "browser handoff".
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
---

# Browser Queue

List and manage pending browser tasks.

## Procedure

1. Scan `~/cockpit/state/browser-queue/` for `.request.md` files
2. For each, check if a matching `.response.md` exists
3. Report:
   - **Pending**: requests without responses -- show the Teams command to copy-paste
   - **Completed**: requests with responses -- show summary, offer to feed back to agent
   - **Stale**: requests older than 24h without response -- flag for attention
4. For completed responses:
   - If the originating agent task is still running, the response will be picked up automatically
   - If the agent finished while waiting, offer to launch a follow-up agent with the response context
5. Clean up: offer to archive completed request/response pairs to `~/cockpit/state/browser-queue/archive/`
