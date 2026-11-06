---
name: sandbox-work
description: Coordinate an ADO coding task through an isolated Docker Sandbox VM. Use when the user says "sandbox work item", "Docker sandbox workflow", "run this bug in sbx", or wants implementation isolated from the host.
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
Azure Artifacts credentials may be passed only to the constrained
package-manager process used by `sbx-host.seed`. The PAT is acquired through
Windows AzureAuth so Conditional Access uses the authenticated Windows session.
Lifecycle scripts are disabled while the short-lived package-read PAT exists.

## Procedure

1. Fetch the complete ADO item and assess fitness.
2. Resolve unclear reproduction or design questions on the host.
3. Call `sbx-host.inspect` for the work-item ID:
   - If `sandboxStatus` is `present`, verify the repository, branch, base, and
     VM path, then resume that sandbox.
   - If metadata is absent or `sandboxStatus` is `missing-unexported`, identify
     the repository and slug, then call
     `sbx-host.seed`. Seed automatically restores dependencies when the
     canonical repository declares a supported package manager and configures
     an Azure Artifacts registry.
     Seed returns immediately; call `sbx-host.inspect` with `waitSeconds: 60`
     until it reports `sandboxStatus: present`. Do not use shell sleeps or start
     another seed while `seedStatus` is `running`.
   - If `sandboxStatus` is `missing-exported`, stop and preserve the metadata
     and host worktree for review.
4. Build a bounded implementation prompt containing the work-item requirements,
   VM repository path and branch, repository-instruction requirement, validation
   expectations, commit trailers, and the prohibition on push/PR/external
   credentials. Do not include host secrets or unrelated session context.
5. Call `sbx-host.dispatch`. Poll `sbx-host.task_status` and read
   `sbx-host.task_logs` until it completes. Do not use shell sleeps or ask the
   user to proxy the prompt/results through an interactive terminal.
6. If the task returns a question or bounded blocker, resolve it on the host and
   dispatch a fresh follow-up task in the same VM. Each dispatch is a fresh
   Copilot process with the repository state and dependencies preserved.
7. The VM task must read the repository's `AGENTS.md`, `README.md`, and package
   metadata; run required post-restore setup; implement; validate; and commit
   without push or PR. Seed creates user-local package-manager shims and
   configures repository-local Git identity.
8. If Balanced networking blocks a required package or API host, inspect the
   Docker policy log and add only the required sandbox-scoped rule:

   ```bash
   sbx policy allow network --sandbox wi-<work-item>-vm '<host-rule>'
   ```

9. Use checkpoints:
   - baseline setup and tests
   - structural comparison and data-flow trace
   - one root-cause theory
   - failing regression test
   - minimal implementation
   - focused and full validation
   - commit without push or PR
10. Keep browser reproduction and live network inspection on the host.
11. When the VM has a clean committed change:
    - Call `sbx-host.export`.
    - Confirm export reports that the rebased commit preserved the VM patch.
12. Review the host worktree diff against the work item. If the rebase was
    clean, the patch was preserved, and no host edits are needed:
    - Push only the expected `users/alwaibel/agent/<id>-<slug>` branch.
    - Follow any repository PR skill, template, and instructions.
    - Compose the PR from the work item, final diff, and verified outcomes; do
      not copy the VM handoff or result text into the PR.
    - Apply the global External Artifact Hygiene policy before creating the
      draft PR. Repository conventions are additive.
    - Let CI validate the final rebased commit.
13. Call `sbx-host.sync` only when conflicts, host review, or requested
    follow-up require more VM work. Prefer a fresh VM Copilot session for that
    validation rather than returning to the implementation context.
14. Stop the VM for PR follow-up using Docker directly:

   ```bash
   sbx stop wi-<work-item>-vm
   ```

15. Remove it only after all VM commits are exported:

    ```bash
    sbx rm wi-<work-item>-vm
    ```

## Recovery

- Transfer metadata is stored under `~/.local/state/sbx-work/`.
- Dispatched task metadata and logs are stored under
  `~/.local/state/sbx-work/tasks/`.
- A reboot or daemon restart should not require recreating the sandbox.
- Interactive `sbx run --name wi-<work-item>-vm` remains a manual diagnostic
  fallback, not the normal implementation path.
- Seed is atomic: an incomplete new sandbox is removed and no metadata is
  retained. Retry seed after correcting the reported failure.
- If Copilot reports expired or unauthorized credentials, ask the user to run:

  ```powershell
  gh auth status --hostname github.com
  sbx secret set github `
    --command 'gh auth token --hostname github.com' `
    --refresh on-demand
  sbx secret set copilot `
    --command 'gh auth token --hostname github.com' `
    --refresh on-demand
  sbx stop wi-<work-item>-vm
  sbx run --name wi-<work-item>-vm
  ```

  If `gh auth status` fails, run `gh auth login --hostname github.com` first.
- If export or synchronization fails, keep both the VM and host worktree. Do not
  delete state or bypass bundle verification.
- Before running `sbx rm`, confirm the VM is clean and its HEAD matches the
  exported or synchronized host commit.

## Repository behavior

The `sbx-host` MCP server is the constrained host bridge. It exposes only
seed/inspection, bounded Copilot dispatch/status/logs/cancel, export, and
exceptional sync. It does not expose arbitrary host commands or paths.
Lifecycle, policy, diagnostics, and removal remain native `sbx` operations.
