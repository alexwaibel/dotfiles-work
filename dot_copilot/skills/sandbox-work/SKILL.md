---
name: sandbox-work
description: Run an ADO coding task through an isolated Docker Sandbox VM using the sbx-work helper. Use when the user says "sandbox work item", "Docker sandbox workflow", "run this bug in sbx", or wants an autonomous implementation isolated from the host.
allowed-tools: shell
---

# Sandbox Work

Coordinate a work item from the trusted host while plain Copilot performs code
investigation and implementation inside a mountless Docker Sandbox VM.

## Trust boundary

The host session owns:

- ADO work-item and pull-request operations
- authenticated Git fetch, rebase, push, and PR creation
- browser reproduction and external MCP tools
- review of imported commits

The VM owns:

- repository exploration
- source and test changes
- dependency execution
- commits on `users/alwaibel/agent/*`

Never give the VM ADO, Teams, mail, deployment, or Git-remote credentials.
Azure Artifacts credentials may be passed only to the dependency-install
process by `sbx-work create`; they must not be present in the Copilot process.

## Procedure

1. Fetch the complete ADO item and assess fitness before creating a sandbox.
2. Resolve unclear reproduction or design questions on the host.
3. Run:

   ```bash
   sbx-work doctor <repo>
   sbx-work create <work-item> <slug> <repo>
   sbx-work run <work-item>
   ```

4. After Copilot starts, change to the path printed by `sbx-work run`.
5. Have the VM agent read the repository's `AGENTS.md`, `README.md`, and
   package metadata to determine setup and validation commands.
6. When a setup command needs Azure Artifacts authentication, run it from the
   trusted host without exposing the token to Copilot:

   ```bash
   sbx-work ado-exec <work-item> -- <command> [args...]
   ```

7. If Balanced networking blocks a required package or API host, inspect the
   Docker policy log and add only the required sandbox-scoped rule:

   ```bash
   sbx-work allow-network <work-item> '<host-rule>'
   ```

8. Use checkpoints:
   - baseline setup and tests
   - structural comparison and data-flow trace
   - one root-cause theory
   - failing regression test
   - minimal implementation
   - focused and full validation
   - commit without push or PR
9. Keep browser reproduction and live network inspection on the host.
10. When the VM has a clean committed change:

   ```bash
   sbx-work import <work-item>
   sbx-work sync <work-item>
   ```

11. After `sync`, rerun the repository-defined validation inside the VM.
12. Review the host worktree diff against the work item. Push only the expected
    `users/alwaibel/agent/<id>-<slug>` branch and create a draft PR.
13. Stop the VM for PR follow-up:

   ```bash
   sbx-work stop <work-item>
   ```

14. Remove it only after all VM commits are exported:

    ```bash
    sbx-work remove <work-item>
    ```

## Recovery

- `sbx-work status [id]` shows persisted state under
  `~/.local/state/sbx-work/`.
- A reboot or daemon restart should not require recreating the sandbox.
- If import or validation fails, keep both the VM and host worktree. Do not
  delete state or bypass bundle verification.
- `sbx-work remove --force` discards unexported work and requires explicit user
  approval.

## Repository behavior

`sbx-work` discovers the default branch from `origin/HEAD` and does not encode
repository setup, dependency, test, or validation commands. Those belong to
the repository and must be discovered from its checked-in instructions.
