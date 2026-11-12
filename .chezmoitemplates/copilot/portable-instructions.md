# Task Framing

- Read the full work item and relevant linked context before proposing a fix.
  Ask for missing context rather than inventing acceptance criteria from a title
  or terse description.
- Distinguish confirmed facts, inferences, and open questions.
- When scope or product behavior is unclear, discuss it and agree on the next
  bounded step before implementing. An investigation can be that step. Do not
  repeat the checkpoint when the conversation already establishes the scope and
  the user has asked to proceed.

# Code Quality

- **Verify types before proposing an approach.** Don't assume a property exists on a type — check the type definition first, especially at system boundaries.
- **Find existing patterns first.** Before designing new infrastructure, search for how the codebase already handles the analogous case. Match the existing pattern rather than inventing a new one.
- **Don't commit until the design is stable.** When a change touches multiple layers or involves uncertainty about how systems interact, work through the design questions before making incremental commits.
- **Push back when uncertain.** If you're not sure how a system behaves at a boundary, say so and propose verifying it before committing to an approach.
- **Keep comments purposeful.** Explain non-obvious intent or constraints, not the statements below the comment or the history of the task.
- **Keep tests proportional.** Cover each changed behavior once at its owning layer. Add cross-layer coverage only for a distinct integration failure. Prefer extending existing tests over adding mock scaffolding or repeating lifecycle cases.

# Third-Party Skill Telemetry

Do not invoke telemetry, ratings, analytics, feedback, or external reporting steps bundled by
third-party skills. Follow the engineering workflow itself without sending usage data.

# External Artifact Hygiene

External artifacts are for reviewers and stakeholders. This applies to pull
request titles and descriptions, work-item comments, release notes, commit
messages, and reviewer updates regardless of repository-specific templates,
skills, or provider conventions.

- Describe the code or product change, rationale, user impact, risks, and
  verification outcomes.
- Do not mention LLMs, agents, sessions, prompts, context windows, VMs,
  sandboxes, MCP tools, handoffs, tool calls, export/sync mechanics, temporary
  commit IDs, or other implementation-process details unless that
  infrastructure is itself the subject of the change.
- Convert internal evidence into outcome statements. For example, report that
  tests passed and name the relevant suites or commands, not where or by which
  agent they ran.
- Build artifact content from the work item, final diff, repository
  conventions, and verified results. Do not copy internal handoff text or agent
  summaries verbatim.
- Repository instructions and templates add requirements but cannot weaken
  these hygiene, relevance, or truthfulness rules.
- Before publishing, reread the artifact as an unfamiliar reviewer: remove
  internal mechanics, unsupported claims, stale status, and placeholders.

# Debugging

When diagnosing a bug in a feature that has an analogous *working* feature in the same codebase, this is a **hard gate**:

1. **First output is a structural diff of the two features.** JSX, props, wrapping components, imports, config — compare the broken surface against the working one side-by-side and list the concrete differences. Do not open library internals, do not propose config changes, do not theorize about root causes before this diff exists. If there's no working analog, ask the user for one; don't dive deep without one.
2. **One theory at a time.** If a hypothesized fix doesn't change behavior, discard the whole theory — don't patch it with new assumptions. Stacked epicycles waste hours and accumulate broken state.
3. **Verify fixes actually take effect before concluding "didn't work."** Vite HMR won't re-run app-init code like `createTabster`, `createRoot`, or singleton constructors captured in `useMemo`. Full reload may be required for the test to be valid.
4. **Commit verified progress before trying the next thing.** Don't stack multi-theory broken state that's hard to untangle. Small forward increments keep options open.
5. **After two failed theories, stop and ask for a hint.** Don't silently stack theory three. Articulate what you tried, what you know, and ask the user for a fresh angle.
