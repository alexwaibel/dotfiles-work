---
name: bug-reproduction-brief
description: Turn a vague, intermittent, or environment-specific bug report into a minimal evidence-backed reproduction before diagnosis or repair. Use for incomplete bug reports, flaky failures, and suspected environment differences.
license: MIT
metadata:
  x-origin-url: "https://raw.githubusercontent.com/github/awesome-copilot/main/skills/bug-reproduction-brief/SKILL.md"
  x-origin-repository: "https://github.com/github/awesome-copilot"
  x-origin-path: "skills/bug-reproduction-brief/SKILL.md"
  x-origin-revision: "3a685010a7afdc0dbd4c83b7fbda6c316aa516e5"
  x-origin-sha256: "522ad2948c498f6dcee6d48773387058d2cba3c45ba9e093ed35210601d141b6"
  x-local-adaptations: "Condensed while preserving the reproduction-before-repair boundary."
---

# Bug Reproduction Brief

Prove the smallest observable failure without changing implementation code.

## Process

1. Record the exact error or incorrect behavior, timestamp, affected command or route, and
   smallest known input. Mark second-hand reports as unverified.
2. Record inspectable environment facts: repository and commit, runtime and package manager,
   operating system or container, lockfile, relevant flags, and deployment tier.
3. Separate behavior from suspected cause:

   ```text
   Expected: [observable result]
   Actual:   [observable result, status, or error]
   ```

4. Remove unrelated inputs, services, and steps one at a time. Restore the last condition when
   removal makes the failure disappear.
5. Run the minimal reproduction at least twice when safe. For intermittent failures, report the
   observed frequency and duration.
6. Stop before repair. The verified reproduction is the deliverable.

## Output

```markdown
# Bug Reproduction Brief

- Target and commit:
- Environment:
- Expected:
- Actual:
- Minimal steps:
- Minimal fixture:
- Reproduced: yes / no / intermittent
- Evidence:
- Unknowns:
- Safe next hypothesis:
```

## Safety

- Prefer isolated tests and read-only requests over production reproduction.
- Do not expose credentials, customer records, private URLs, or sensitive payloads.
- Do not infer root cause from correlation.

## Source

Adapted from GitHub Awesome Copilot's `bug-reproduction-brief` skill:
https://github.com/github/awesome-copilot/tree/main/skills/bug-reproduction-brief
