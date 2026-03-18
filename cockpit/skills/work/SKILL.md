---
name: work
description: Assess agent fitness for ADO work items, run a planning phase, and launch background agents for implementation or investigation. Use when the user says "work", "start work on", "pick up items", "launch agents", or provides work item IDs to implement.
argument-hint: "[work-item-id...]"
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
  - Grep
  - Agent
  - TaskCreate
  - mcp__azure-devops__wit_get_work_item
  - mcp__azure-devops__wit_add_work_item_comment
  - mcp__azure-devops__wit_update_work_item
---

# Work

Assess agent fitness for items, propose a plan, launch on user confirmation.

## Arguments

`$ARGUMENTS` — optional space-separated work item IDs. If omitted, auto-select next queued items by ADO priority.

## Procedure

1. Read state file (`~/cockpit/state/ado-tasks.md`). If empty/stale, run `/standup` first.
2. Count items with Status=`in-progress`. If >= 3 -> report "at capacity", stop.
3. Select items:
   - If IDs given: use those (fetch from ADO and add to state file if not tracked yet)
   - If no IDs: pick up to (3 - active) queued items by ADO priority (fetch live). Batched items count as 1 slot.
4. **Assess fitness** — fetch full description via `wit_get_work_item` (expand=all):
   - Scope clear enough to implement? -> `ready`
   - Root cause unknown but researchable in code? -> `investigate`
   - Requirements vague / needs design? -> `needs-spec`
   - Needs internal tooling / dashboards / manual deploys? -> `needs-human`

## Planning phase — required before launching any agent

The goal is to maximize the chance an agent completes autonomously. Upfront discussion is cheap; failed agent runs are expensive. Never launch an agent on a vague or assumption-laden plan.

5. **Trace the data flow** — for changes that cross system boundaries (e.g., service -> resolver -> GraphQL -> framework -> UI), explicitly map the full chain before planning. At each boundary, note:
   - What types/interfaces constrain the data? (check the actual type definitions, not assumptions)
   - Does the framework transform, wrap, or strip fields? (e.g., Relay strips GraphQL error fields to `PayloadError`)
   - Are there existing patterns for the analogous success path or similar error handling?

6. **Identify gaps** — for each item, flag what's unclear or assumed:
   - Is the root cause known and verified, or hypothesized?
   - Are the reproduction steps concrete?
   - Which files/areas need to change? Can you identify them now?
   - Are there multiple possible approaches? Which is best and why?
   - Does the fix depend on environment, config, or external state the agent can't access?
   - Are there type constraints or framework behaviors at boundaries that need verification before committing to an approach?

7. **Present findings to user** — for each item show:
   - Fitness assessment with rationale
   - Gaps/assumptions identified (bulleted list)
   - Proposed plan: specific files to change, approach, and risks
   - Recommended action: `plan more` / `investigate first` / `ready to launch`

8. **Iterate with user** — discuss until the plan is concrete enough that:
   - The exact files and approach are identified
   - Assumptions are validated (reproduce the issue if possible)
   - The agent prompt will contain specific, actionable instructions (not vague goals)
   - Edge cases and risks are acknowledged

   This may take multiple rounds. That's fine — it's better than a failed agent run.

9. **Break into small units** — decompose the plan into small, atomic changes that can each be committed independently. Each unit should be self-contained and leave the codebase in a working state.

   Examples of good bisection:
   - Rename/move separate from behavior changes
   - Test infrastructure (helpers, fixtures) separate from test implementations
   - Config/schema changes separate from code that uses them
   - Mechanical refactors separate from new features

10. **Post plan to ADO** — add a comment on the work item with the finalized plan (units, files, approach, risks, open questions). This creates a record of what was agreed and gives reviewers context.

11. **Launch** — on user confirmation, for each approved item:
    - **Code agents**: Read the agent prompt template from `~/cockpit/skills/work/references/agent-prompt-code.md`. Substitute placeholders (`<ID>`, `<TITLE>`, `<Full description from ADO>`, `<repo path>`, etc.) with actual values. Launch background Agent (isolation: "worktree", run_in_background: true). Create in-session task via TaskCreate. Update state -> `in-progress`, set Branch.
    - **Investigation agents**: Read the agent prompt template from `~/cockpit/skills/work/references/agent-prompt-investigate.md`. Substitute placeholders. Launch background Agent (run_in_background: true). Create in-session task. Update state -> `in-progress`.
    - **Deferred items**: Update state -> `blocked` or `skipped` with rationale.

12. Update state file.
