---
name: systematic-debugging
description: Diagnose build failures, test errors, runtime crashes, UI bugs, and unexpected behavior using reproduction, structural comparison, one hypothesis at a time, and evidence-based verification. Use when asked to debug, troubleshoot, investigate a failure, find root cause, or fix a failing test.
license: MIT
metadata:
  x-origin-url: "https://raw.githubusercontent.com/obra/superpowers/main/skills/systematic-debugging/SKILL.md"
  x-origin-repository: "https://github.com/obra/superpowers"
  x-origin-path: "skills/systematic-debugging/SKILL.md"
  x-origin-revision: "8ca22dba9a94f28898bbce59f2537ff4d87c747d"
  x-origin-sha256: "808fc5717aa88ad65efff312b11c186294d3e6ee301afb584e2f86599b137787"
  x-local-adaptations: "Added working-analog structural diff gate, full-reload verification, progress commits, and stop after two failed theories."
---

# Systematic Debugging

Find and verify the root cause before implementing a fix.

## Hard gates

1. Reproduce the failure and capture exact evidence.
2. If an analogous working feature exists, the first diagnostic output must be a structural
   side-by-side comparison: files, imports, types, configuration, wrappers, props, lifecycle,
   and tests. Do not inspect library internals or propose configuration changes first.
3. Test one explicit hypothesis at a time with the smallest discriminating experiment.
4. Verify that the experiment actually took effect. Restart or fully reload when hot reload
   cannot re-run initialization or singleton construction.
5. After a failed theory, remove its experimental changes and discard the theory.
6. After two failed theories, stop, summarize the evidence, and ask the user for a fresh angle.
7. Commit verified progress before starting a materially different theory when the user has
   requested commits or the investigation already has stable changes.

## Process

### 1. Establish the baseline

- Read the complete error and stack trace.
- Identify the narrowest command or interaction that reproduces it.
- Determine whether it is deterministic.
- Check relevant recent changes and environment differences.
- Trace values and state across each component boundary.

If no working analog exists and the diagnosis depends on one, ask the user to identify it.

### 2. Compare patterns

- Read the working and broken implementations completely.
- List every concrete structural difference before judging relevance.
- Verify actual boundary types, configuration sources, initialization order, and framework
  transformations.

### 3. State and test one theory

Use this form:

```text
Theory: [specific root-cause claim]
Evidence supporting it: [observations]
Experiment: [smallest test that distinguishes true from false]
Result: confirmed / denied / inconclusive
```

Do not stack fixes, change multiple variables, or preserve a denied experiment.

### 4. Fix and verify

- Add or identify a failing regression test when practical.
- Implement one root-cause fix without unrelated cleanup.
- Re-run the original reproduction and the smallest relevant build/test checks.
- Remove temporary instrumentation.
- State any proof layer that could not be exercised.

## Source

Adapted from `obra/superpowers` systematic debugging and the AI Starter Pack
hypothesis-driven debugging workflow:
https://github.com/obra/superpowers/tree/main/skills/systematic-debugging
