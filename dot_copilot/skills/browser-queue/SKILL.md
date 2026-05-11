---
name: browser-queue
description: List and manage pending browser tasks in the WSL-to-Windows handoff queue. Use when the user says "browser queue", "pending browser tasks", "check browser requests", or "browser handoff".
allowed-tools: shell
---

# Browser Queue

List and manage pending browser tasks.

## Procedure

1. Scan `~/cockpit/state/browser-queue/` for `.request.md` files
2. For each, check if a matching `.response.md` exists
3. Report:
   - **Pending**: requests without responses — show the Teams command to copy-paste
   - **Completed**: requests with responses — show summary, offer to feed back into the current session
   - **Stale**: requests older than 24h without response — flag for attention
4. For completed responses: offer to read the response file and use its findings to continue work
5. Clean up: offer to archive completed request/response pairs to `~/cockpit/state/browser-queue/archive/`
