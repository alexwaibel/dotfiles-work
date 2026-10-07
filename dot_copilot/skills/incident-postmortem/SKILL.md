---
name: incident-postmortem
description: Write a structured, blameless postmortem for a production incident, significant degradation, or near miss with timeline evidence, quantified impact, systemic root causes, and owned action items. Use for postmortems, incident reviews, outage reports, RCAs, and lessons learned.
license: MIT
metadata:
  x-origin-url: "https://raw.githubusercontent.com/github/awesome-copilot/main/skills/incident-postmortem/SKILL.md"
  x-origin-repository: "https://github.com/github/awesome-copilot"
  x-origin-path: "skills/incident-postmortem/SKILL.md"
  x-origin-revision: "3a685010a7afdc0dbd4c83b7fbda6c316aa516e5"
  x-origin-sha256: "0492b8e05eba16cf045041b519536f906b06b278c77a0a33b4b947ed0b79176b"
  x-local-adaptations: "Added significance and duplicate-postmortem eligibility gates; condensed the output template."
---

# Incident Postmortem

Capture durable learning from a meaningful production incident without assigning personal blame.

## Eligibility gate

Before drafting:

1. Confirm the event escaped to production or was a significant near miss.
2. Confirm user, service, data, or SLO impact was meaningful.
3. Confirm the root cause or interaction is non-obvious enough to teach something durable.
4. Search the repository's existing incident/postmortem location for the same root cause.

If these conditions are not met, recommend a bug report, runbook update, or brief incident note
instead.

## Evidence gathering

Collect:

- title, date, severity, detection and resolution times, and incident owner;
- affected services, users or traffic, error rate, data impact, and SLO/SLA impact;
- timestamped evidence from alerts, logs, deployments, communications, and mitigations;
- what worked, what delayed response, and where safeguards failed.

Mark unknowns explicitly. Prefer UTC and distinguish symptom start, detection, mitigation, and
full recovery.

## Analysis

- Use Five Whys or equivalent causal tracing until reaching a fixable system or process gap.
- Separate the root cause from contributing factors and trigger conditions.
- Replace blame language with system language: "the process lacked" rather than "a person
  forgot."
- Do not call "human error" a root cause.

## Action items

Every action must be a concrete deliverable with an owner, due date, priority, and link to a
specific cause or contributing factor. Reject vague items such as "improve monitoring."

## Output

```markdown
# Postmortem: [title]

## Summary
## Impact
## Detection and Response
## Timeline
## Root Cause
## Contributing Factors
## What Went Well
## What Could Have Gone Better
## Action Items
## Lessons Learned
## Evidence and Open Questions
```

## Source

Adapted from GitHub Awesome Copilot's `incident-postmortem` skill:
https://github.com/github/awesome-copilot/tree/main/skills/incident-postmortem
