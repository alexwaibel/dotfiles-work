---
name: work
description: Assess fitness for an ADO work item, plan implementation, and walk through it in the current session. Use when the user provides one or more work item IDs and wants to start implementation.
allowed-tools: shell
---

# Work

> **Note — Copilot CLI migration:** the original Claude Code version of this
> skill launched up to 3 background subagents in parallel (`Agent` with
> `run_in_background: true`), each working in its own worktree. Copilot CLI is
> a single-agent CLI without subagent launching, so this rewrite drops the
> parallelism and walks through one item at a time in the active session. The
> reference prompts in `references/` describe the original autonomous-agent
> flow and need rework before they're useful again. Treat this skill as a
> structured planning aid for now.

Assess fitness, propose a plan, then walk through implementation in the
current session.

## Arguments

Optional space-separated work item IDs. If omitted, auto-select the next
queued item by ADO priority. Process one item at a time (no parallelism).

## Procedure

1. Read state file (`~/cockpit/state/ado-tasks.md`). If empty/stale, run `/standup` first.
2. Select one item (highest-priority queued, or specified by user).
3. **Assess fitness** — fetch full description via `wit_get_work_item` (expand=all):
   - Scope clear enough to implement? -> `ready`
   - Root cause unknown but researchable in code? -> `investigate`
   - Requirements vague / needs design? -> `needs-spec`
   - Needs internal tooling / dashboards / manual deploys? -> `needs-human`

## Planning phase — required before writing code

The goal is to maximize the chance of completing autonomously. Upfront discussion is cheap; broken implementation attempts are expensive. Never start coding on a vague or assumption-laden plan.

4. **Trace the data flow** — for changes that cross system boundaries (e.g., service -> resolver -> GraphQL -> framework -> UI), explicitly map the full chain before planning. At each boundary, note:
   - What types/interfaces constrain the data? (check the actual type definitions, not assumptions)
   - Does the framework transform, wrap, or strip fields?
   - Are there existing patterns for the analogous success path or similar error handling?

5. **Identify gaps** — flag what's unclear or assumed:
   - Is the root cause known and verified, or hypothesized?
   - Are the reproduction steps concrete?
   - Which files/areas need to change? Can you identify them now?
   - Are there multiple possible approaches? Which is best and why?
   - Does the fix depend on environment, config, or external state?
   - Are there type constraints or framework behaviors at boundaries that need verification before committing to an approach?

6. **Present findings to user**:
   - Fitness assessment with rationale
   - Gaps/assumptions identified (bulleted list)
   - Proposed plan: specific files to change, approach, and risks
   - Recommended action: `plan more` / `investigate first` / `ready to implement`

7. **Iterate with user** — discuss until the plan is concrete enough that:
   - The exact files and approach are identified
   - Assumptions are validated (reproduce the issue if possible)
   - Edge cases and risks are acknowledged

8. **Break into small units** — decompose into small, atomic changes each committable independently. Each unit should be self-contained and leave the codebase in a working state.

   Examples of good bisection:
   - Rename/move separate from behavior changes
   - Test infrastructure (helpers, fixtures) separate from test implementations
   - Config/schema changes separate from code that uses them
   - Mechanical refactors separate from new features

9. **Post plan to ADO** — add a comment on the work item with the finalized plan (units, files, approach, risks, open questions).

## Implementation phase

10. Create an isolated worktree:
    ```bash
    cd <repo path>
    git fetch origin
    git worktree add .copilot/worktrees/<id>-<slug> -b {{ .ado.branchPrefix }}<id>-<slug> origin/master
    cd .copilot/worktrees/<id>-<slug>
    ```
    Always branch from `origin/master` (or `origin/main` — check which exists) so the base is the latest remote state. Never branch from the local `master`.

11. Read the repo's `AGENTS.md` (or `CLAUDE.md` if still present) for build/test/lint commands.

12. Run the full test suite. All tests MUST pass before writing any code. If tests fail on a clean checkout, stop and report.

13. Work through the plan one unit at a time:
    a. Write a failing test that reproduces the bug or validates the change (RED)
    b. Implement the minimal fix/feature to make the test pass (GREEN)
    c. Refactor if needed while keeping tests green
    d. Run the full test suite — all tests must pass
    e. Commit with a descriptive message. Do NOT use `AB#` prefixes — work items are linked via the PR, not commit messages.

14. **Self-review** — run `git diff main...HEAD` and evaluate:
    - **Correctness**: does this fix/implement the work item?
    - **Scope**: are ALL changes related to this work item? Revert any unrelated changes.
    - **Tests**: are existing tests passing? Are new tests present where needed?
    - **Style**: does the code match the repo's conventions?

15. Push branch and open a DRAFT PR:
    a. Check for PR conventions (`.azuredevops/pull_request_template.md`, `.github/pull_request_template.md`, or PR instructions in `AGENTS.md`/`CLAUDE.md`).
    b. Create a draft PR via `az repos pr create --work-items <ID>` with a descriptive title (no `AB#` prefix).
    c. Draft only, link work items, no `AB#` prefix in the title.

16. **Clean up worktree**:
    ```bash
    cd <repo path>
    git worktree remove .copilot/worktrees/<id>-<slug>
    ```

17. Post an ADO comment with: summary of changes, PR link, open questions.

18. Update ADO work item state to Active if currently Proposed.

## Notifications

Post to Teams at key moments (starting, opening PR, blocked, done):

```bash
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/teams/{{ .teams.teamId }}/channels/{{ .teams.channelId }}/messages" \
  --headers "Content-Type=application/json" \
  --body '{"body":{"contentType":"html","content":"<b>[WI#<ID>]</b> <status message>"}}'
```

## Safety
- ONLY modify files related to this work item
- ONLY push to branch: `{{ .ado.branchPrefix }}<id>-<slug>`
- ONLY open DRAFT PRs — never publish or merge
