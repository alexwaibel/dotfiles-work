---
name: sandbox-work
description: Coordinate an ADO coding task through an isolated Docker Sandbox VM. Use when the user says "sandbox work item", "Docker sandbox workflow", "run this bug in sbx", or wants implementation isolated from the host.
---

# Sandbox Work

Coordinate a work item from the trusted host while plain Copilot performs code
investigation and implementation inside a Docker Sandbox private clone.

## Trust boundary

The host session owns:

- ADO work-item and pull-request operations
- authenticated Git fetch, rebase, push, and PR creation
- browser reproduction and external MCP tools
- review of imported commits

The `sbx` adapter alone handles Windows executable discovery, host-path
conversion, and environment forwarding. A separate
package credential provider handles Windows AzureAuth. Transfer, worktrees,
rebasing, and publishing use Linux Git, never Windows Git.

The VM owns:

- repository exploration
- source and test changes
- dependency execution
- commits on `users/alwaibel/agent/*`

Never give the VM ADO, Teams, mail, deployment, or Git-remote credentials.
New VMs are mountless. Linux Git bundles seed a private checkout from the selected
remote commit without mounting the host repository or exposing ignored,
untracked, or uncommitted host files. The VM checkout has no Git remote.
Existing clone-mode VMs remain usable but retain their original read-only mount.
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
   - If no sandbox exists, determine whether the expected agent branch already
     exists remotely:
     - For new work, call `sbx-host.seed` with
       `reuseExistingBranch: false`; the branch must not already exist.
     - For an existing PR or follow-up iteration, call `sbx-host.seed` with
       `reuseExistingBranch: true`; the current remote PR branch head becomes
       the sandbox baseline. Existing metadata is preserved if seed fails.
       Host worktrees are independent of sandbox preparation.
   - Seed automatically restores dependencies when the canonical repository
     declares a supported package manager and configures an Azure Artifacts
     registry.
     Seed returns immediately with the same persisted task result as dispatch.
     Use the one-shot
     `sbx-work task-wait <task-id>` procedure in step 5, then call
     `sbx-host.inspect` once to verify readiness. Do not start another seed
     while the existing seed job is active.
4. Build a bounded implementation prompt containing the work-item requirements,
   VM repository path and branch, repository-instruction requirement, validation
   expectations, commit trailers, and the prohibition on push/PR/external
   credentials. Do not include host secrets or unrelated session context.
5. Call `sbx-host.dispatch`, then run `sbx-work task-wait <task-id>` once as
   an attached background shell command (`mode: "async"`, without detach).
   The command watches local task metadata and returns the terminal status
   plus a bounded log tail; shell completion wakes the host session.
   Continue independent work or yield until that completion notification,
   then read the command output once. Do not poll status, repeatedly fetch
   log tails, or create short-lived sleep/watch loops.
   The default wait deadline is 1800 seconds; an optional second argument
   selects 1-3600 seconds. Exit 124 means the deadline elapsed, not that the
   task was canceled. On timeout, inspect status/logs once and reassess with
   the user rather than automatically rearming the waiter or dispatching
   another task. Use `sbx-host.task_status` and `sbx-host.task_logs` for
   recovery or an explicit progress request, not routine monitoring.
   Do not ask the user to proxy the prompt/results through a terminal.
6. If the task returns a question or bounded blocker, resolve it on the host and
   dispatch a fresh follow-up task in the same VM. Each dispatch is a fresh
   Copilot process with the repository state and dependencies preserved.
7. The VM task must read the repository's `AGENTS.md`, `README.md`, and package
   metadata; run required post-restore setup; implement; validate; and commit
   only when authorized, without push or PR. Seed creates user-local package-manager shims and
   configures repository-local Git identity.
8. If Balanced networking blocks a required package or API host, inspect the
   Docker policy log and add only the required sandbox-scoped rule:

   ```bash
   sbx policy allow network --sandbox wi-<work-item>-vm '<host-rule>'
   ```

9. Keep tasks bounded: establish a baseline, investigate, implement the smallest
   fix, validate, and commit only when authorized.
10. Keep browser reproduction and live network inspection on the host.
11. When the VM has a clean committed change:
    - Call `sbx-host.export`. It creates a VM Git bundle, copies it through
      `sbx`, verifies prerequisites and the exact branch/HEAD, and imports into
      a dedicated immutable ref using Linux Git. It does not fetch origin,
      alter a host worktree, or rebase.
    - Confirm `importedCommit` matches VM HEAD.
    - Use ordinary Linux Git commands on the host to fetch, create or reuse
      `~/repos/worktrees/<repo>/<branch-slug>`, and integrate the imported ref.
      Choose fast-forward, cherry-pick, or rebase based on the actual history
      and the user's instructions. The bridge does not make these decisions.
      Preserve both histories on conflicts or uncertainty; inspect the diff
      and use normal Git recovery rather than transfer metadata.
12. Review the final host diff against the work item and validate the final
    revision before publishing:
    - Push only the expected `users/alwaibel/agent/<id>-<slug>` branch.
    - Follow any repository PR skill, template, and instructions.
    - Compose the PR from the work item, final diff, and verified outcomes; do
      not copy the VM handoff or result text into the PR.
    - Apply the global External Artifact Hygiene policy before creating the
      draft PR. Repository conventions are additive.
    - Let CI validate the final rebased commit.
13. Call `sbx-host.sync(workItem, commit)` only when host integration or requested
    follow-up requires more VM work. Pass the explicit full reviewed commit SHA
    available in the canonical repository's object store. Sync transfers only
    that committed revision; it does not include uncommitted host changes.
    It rejects a dirty VM or unexpected branch, transfers a self-contained
    bundle, and verifies the resulting VM HEAD. It does not fetch or rebase.
    Prefer a fresh validation-only dispatch for checking the integrated commit.
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
- Seed and Copilot task status and logs are stored under
  `~/.local/state/sbx-work/tasks/`.
  The private worker alone writes status; dispatch returns after its startup
  acknowledgement. Prompts use private IPC to the worker and stdin into the VM,
  not host-side prompt files. Readers do not repair state. Cancellation asks the
  worker to terminate the VM process group and confirm it has stopped; stopping
  the host `sbx exec` client alone does not stop VM processes.
  Both task kinds use the same event-driven waiter and survive MCP restarts.
- Seed, dispatch, export, and sync share one nonblocking lock per work item.
  Unrelated work items can proceed independently.
- A reboot or daemon restart should not require recreating the sandbox.
- Interactive `sbx run --name wi-<work-item>-vm` remains a manual diagnostic
  fallback, not the normal implementation path.
- Seed is atomic for ordinary failures: incomplete new sandboxes and transfer
  metadata are removed; the failed job record and logs remain for diagnosis.
  Correct the failure before explicitly retrying. Do not cancel a seed through
  the Copilot-task cancellation operation; lifecycle recovery stays native.
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
- If import or synchronization fails, keep the VM, imported refs, and host
  worktree. Do not delete state or bypass bundle/SHA verification.
- Before running `sbx rm`, confirm the VM is clean and its HEAD matches the
  exact imported or synchronized commit, not merely a rebased host HEAD.

## Repository behavior

The `sbx-host` MCP server is the constrained host bridge. It exposes only
seed/inspection, bounded Copilot dispatch/status/logs/cancel, export, and
exceptional sync. It does not expose arbitrary host commands or paths.
There is one coding-task start operation: `sbx-host.dispatch`. Its subprocess
runner is private, not another CLI command. The only `sbx-work` CLI operation is
`task-wait`; all other bridge operations use MCP. Seed uses the same minimal persisted
status/log mechanism so long dependency restores survive MCP restarts. Inspect
does not wait; use the single `task-wait` completion mechanism for either task.

Both transfer directions use Git bundles and `sbx cp`. Export imports an exact
VM SHA; sync receives an explicit host SHA. Worktree creation, integration,
conflict resolution, and publication are host decisions using ordinary Git,
not bridge commands or a separate Git recovery state machine.

The host implementation is shared JavaScript used directly by MCP and the
one-shot waiter. A private Node worker owns persisted task status. Native
`flock`, atomic file replacement, and filesystem notifications provide locking
and observation without a separate service manager.

Mountless seeding avoids Docker-internal Windows Git and native-clone
compatibility shims. Lifecycle, policy, diagnostics, and removal remain native
`sbx` operations.
