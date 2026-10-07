---
name: git-commit
description: Create safe, well-structured Conventional Commits by analyzing diffs, staging only the intended logical change, and preserving required repository and Copilot trailers. Use when asked to commit changes, stage and commit, write a commit message, or run /commit.
license: MIT
metadata:
  x-origin-url: "https://raw.githubusercontent.com/github/awesome-copilot/main/skills/git-commit/SKILL.md"
  x-origin-repository: "https://github.com/github/awesome-copilot"
  x-origin-path: "skills/git-commit/SKILL.md"
  x-origin-revision: "3a685010a7afdc0dbd4c83b7fbda6c316aa516e5"
  x-origin-sha256: "554d1a3c6d95f15bc1170160659ecdc9a9958b64f377f3988941b672c249b13f"
  x-local-adaptations: "Added explicit-path staging, user-change protection, current Copilot trailers, and no-amend policy."
---

# Git Commit

Create one or more reviewable commits from the actual working-tree state.

## Workflow

1. Inspect `git status --short`, staged and unstaged diffs, the current branch, and recent commit
   style.
2. Identify unrelated, generated, sensitive, or user-owned changes. Do not stage them.
3. Group files by logical purpose. If the requested commit mixes independent changes, propose
   separate commits.
4. Stage explicit paths. Avoid broad staging when the worktree contains unrelated changes.
5. Generate a Conventional Commit message:

   ```text
   <type>[optional scope]: <imperative description>

   [body explaining why and important behavior]

   [issue references and required trailers]
   ```

6. Append every commit trailer required by active instructions, including the current
   `Co-authored-by` and `Copilot-Session` values.
7. Commit non-interactively, then verify the new commit and remaining worktree status.

## Types

`feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.

Use an imperative subject under 72 characters. Explain why in the body when the subject alone
does not preserve intent.

## Safety

- Never change git configuration, rewrite history, amend, force-push, skip hooks, or run a
  destructive reset unless the user explicitly requests it.
- Never stage secrets, credentials, `.env` files, or unrelated user changes.
- If hooks fail, fix failures caused by the intended change and create a new commit attempt.
  Do not bypass hooks.
- Stop on merge conflicts or ambiguous ownership.

## Source

Adapted from GitHub Awesome Copilot and AI Starter Pack `git-commit` skills:
https://github.com/github/awesome-copilot/tree/main/skills/git-commit
