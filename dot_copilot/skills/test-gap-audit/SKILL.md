---
name: test-gap-audit
description: Perform a read-only audit for missing, weak, stale, or mis-scoped behavioral test coverage. Use when asked what tests are missing, whether coverage is sufficient, which regression tests to add, or how to prove a change is safe.
license: MIT
metadata:
  x-origin-url: "https://raw.githubusercontent.com/github/awesome-copilot/main/skills/test-gap-audit/SKILL.md"
  x-origin-repository: "https://github.com/github/awesome-copilot"
  x-origin-path: "skills/test-gap-audit/SKILL.md"
  x-origin-revision: "3a685010a7afdc0dbd4c83b7fbda6c316aa516e5"
  x-origin-sha256: "a7747ac0b60d33ec6a44b9703ae11e8f6bf7aede251f117cc46599d182bfef21"
  x-local-adaptations: "Condensed while retaining read-only scope, behavioral coverage, evidence, priority, and depth-limit requirements."
---

# Test Gap Audit

Identify important behavior that current tests do not prove.

## Rules

- Stay read-only unless the user explicitly asks to add tests.
- Scope to the named feature, PR, branch, route, service, workflow, or bug fix. If no scope is
  named, inventory the repository breadth-first and state which surfaces were not deeply
  inspected.
- Infer test framework, placement, fixtures, mocks, and assertion style before recommending
  tests.
- Treat coverage percentages as leads, not proof. Evaluate behavior, boundaries, and assertions.
- Prefer the lowest reliable test level; do not default to slow end-to-end tests.
- Separate confirmed gaps from inferred risks.

## Process

1. Inspect repository status, manifests, CI, test configuration, naming conventions, and nearby
   tests.
2. Map the behavior: happy path, failures, validation, permissions, state transitions,
   integrations, retries, idempotency, concurrency, compatibility, and user-visible states.
3. Map direct and indirect existing coverage. Check whether assertions prove the claimed
   behavior or mocks remove the important boundary.
4. Identify precise missing scenarios and the smallest test that would prove each one.
5. Run only focused, read-only discovery or existing test commands when useful. Record checks
   run and skipped.

## Priority

- **P0**: no safety net for data loss, security/privacy exposure, destructive actions, billing,
  or likely production outage.
- **P1**: missing coverage for critical user paths, authorization, contracts, migrations, jobs,
  or release-blocking behavior.
- **P2**: meaningful regression risk in errors, validation, state, integrations, retries, races,
  or compatibility.
- **P3**: lower-risk test clarity, stale fixtures, naming, or maintenance.

## Evidence standard

Every finding must cite the behavior or code and the relevant test area. Explain what current
tests prove and do not prove. For inferred gaps, include confidence.

## Output

```markdown
**Test Gap Audit: [scope]**

1. **P1: [gap]**
   - Behavior/risk:
   - Current coverage:
   - Evidence:
   - Suggested test:

**Suggested Test Plan**
**Existing Coverage Worth Keeping**
**Surveyed But Not Deeply Inspected**
**Checks Run**
**Not Tested**
```

## Source

Adapted from GitHub Awesome Copilot's `test-gap-audit` skill:
https://github.com/github/awesome-copilot/tree/main/skills/test-gap-audit
