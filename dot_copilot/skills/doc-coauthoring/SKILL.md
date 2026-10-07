---
name: doc-coauthoring
description: Co-author technical documentation through context gathering, iterative drafting, and reader testing. Use for design docs, RFCs, proposals, specifications, decision records, architecture docs, and substantial documentation.
license: Apache-2.0
metadata:
  x-origin-url: "https://raw.githubusercontent.com/anthropics/skills/main/skills/doc-coauthoring/SKILL.md"
  x-origin-repository: "https://github.com/anthropics/skills"
  x-origin-path: "skills/doc-coauthoring/SKILL.md"
  x-origin-revision: "683bc88e56f3e09ba94f7055977f3d3aa499f202"
  x-origin-sha256: "2e47d78846faeea4a56e9809c52700087a15a2155a3f293a3efbaded81398ef4"
  x-local-adaptations: "Condensed for Copilot CLI; direct drafting allowed when context is sufficient; reader testing uses subagents."
---

# Doc Co-Authoring

Create a document that works for readers who do not share the authors' context.

## Workflow

### 1. Gather context

Determine:

- document type, audience, desired decision or outcome;
- required template, scope, and exclusions;
- background, constraints, alternatives, dependencies, and stakeholder concerns;
- source material available in files, repositories, or connected tools.

If the user already supplied enough context, do not repeat questions. Otherwise ask a focused
set of questions together. Accept shorthand answers and unstructured context dumps.

Exit this stage when remaining questions concern tradeoffs and edge cases rather than basic
facts.

### 2. Structure and draft

1. Propose a short outline appropriate to the document type.
2. Start with the section containing the most uncertainty; write summaries last.
3. Draft into the user-requested location. Do not create a repository document merely for
   planning unless the user asked for one.
4. Refine surgically from feedback instead of rewriting unaffected sections.
5. Check the complete draft for unsupported claims, contradictions, repetition, vague language,
   missing decisions, and generic filler.

Match existing repository terminology and document style when examples exist.

### 3. Reader test

Use a fresh subagent when the document is substantial and the environment supports one:

1. Give the subagent only the document and representative reader questions.
2. Ask it to identify ambiguity, hidden assumptions, contradictions, and unanswered questions.
3. Fix material gaps and repeat only where needed.

For short documents, perform the same checks directly rather than adding process overhead.

## Output

Deliver the document plus a concise list of unresolved facts or decisions. Never present
guesses as verified facts.

## Source

Adapted from Anthropic's `doc-coauthoring` skill:
https://github.com/anthropics/skills/tree/main/skills/doc-coauthoring
