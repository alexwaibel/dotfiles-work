---
name: review
description: Daily review — unified dashboard of ADO sprint items and Logseq TODOs. Use when the user says "review", "daily review", "what's on my plate", "morning review", or "EOD review".
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
  - mcp__azure-devops__work_list_team_iterations
  - mcp__azure-devops__wit_get_work_items_for_iteration
  - mcp__azure-devops__wit_get_work_items_batch_by_ids
  - mcp__azure-devops__wit_my_work_items
  - mcp__azure-devops__wit_get_work_item
  - mcp__azure-devops__wit_create_work_item
  - mcp__azure-devops__wit_add_child_work_items
  - mcp__azure-devops__wit_update_work_item
---

# Review

Generate a unified daily dashboard combining ADO sprint items and Logseq TODOs.

## Config

- Logseq journals: `/mnt/c/Users/alwaibel/OneDrive - Microsoft/Documents/logseq/journals/`
- Logseq format: org-mode (`.org` files), TODO markers: `* TODO`, `** TODO`, `*** TODO`, `* DOING`
- Dashboard output: `~/cockpit/state/daily-dashboard.md`
- ADO config: see `~/cockpit/CLAUDE.md` for org/project/team

## Procedure

### 1. Gather ADO items

1. Fetch current iteration: `work_list_team_iterations` (project: MSTeams, team: Workflows App, timeframe: current)
2. Fetch sprint work items: `wit_get_work_items_for_iteration`
3. Batch-fetch details: `wit_get_work_items_batch_by_ids` (fields: Id, Title, State, WorkItemType, Priority, Tags, IterationPath)
4. Filter to items assigned to alwaibel@microsoft.com
5. Also fetch `wit_my_work_items` to catch items assigned but not in current sprint

### 2. Gather Logseq TODOs

1. Grep journals directory for open TODOs: pattern `^\*+ (TODO|DOING)` in `.org` files
2. Parse each match: extract date from filename, indent level, and task text
3. Include ALL open TODOs (not just recent — the point is nothing slips through)

### 3. Generate dashboard

Write `~/cockpit/state/daily-dashboard.md` with this structure:

```markdown
# Daily Dashboard
- Generated: <ISO timestamp>
- Sprint: <name> (<start> to <end>)

## Current Sprint (ADO)

### Active / In Progress
| ID | Title | Priority | State | Tags |
|----|-------|----------|-------|------|
(sorted by priority asc, then ID desc)

### Blocked
| ID | Title | Priority | Blocked Since | Tags |
|----|-------|----------|---------------|------|

### Proposed / Queued
| ID | Title | Priority | Tags |
|----|-------|----------|------|

## Backlog (assigned but not in sprint)
| ID | Title | Priority | State | Iteration |
|----|-------|----------|-------|-----------|
(only show items in Active or Proposed state, skip Resolved/Closed)

## Logseq TODOs
| Date | Task | Suggested Action |
|------|------|------------------|
(each open TODO with a suggested action — see below)

## Recommendations
(see step 4)
```

### 4. Logseq triage recommendations

For each open Logseq TODO, suggest one of:
- **Promote to ADO** — if it's a standalone deliverable that should be tracked in the sprint. Note which ADO item it might be a child of, if any.
- **Add as child task** — if it's clearly a subtask of an existing ADO item. Identify the parent.
- **Mark DONE** — if it looks like it was already completed (check ADO items, recent context).
- **Keep in Logseq** — if it's a quick reminder or note-to-self that doesn't need formal tracking.

### 5. Present to user

Display the dashboard contents directly in the conversation (don't just say "wrote the file"). Highlight:
- **Top 3 priorities for today** based on: P1/P2 items first, blocked items that need nudging, items with upcoming deadlines
- Any Logseq TODOs recommended for promotion
- Items that look stale (no state change in 2+ sprints)

### 6. Act on user decisions

After presenting, ask the user:
- Which Logseq TODOs to promote (and execute: create ADO items or add as children)
- Which to mark DONE in Logseq (and execute: edit the .org file)
- Any priority adjustments needed

## EOD variant

If the user says "EOD review" or "end of day":
- Skip the recommendations section
- Instead ask: "What did you work on today?" and "Any new TODOs to capture?"
- Update ADO item states based on their answers
- Capture new TODOs directly as ADO items (not Logseq)
