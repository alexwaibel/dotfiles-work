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
package-manager process used by `sbx-host.seed`. Lifecycle scripts are disabled
while that short-lived package-read PAT exists.

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
   - If `sandboxStatus` is `missing-exported`, stop and preserve the metadata
     and host worktree for review.
4. Ask the user to attach from Windows Terminal:

   ```powershell
   sbx run --name wi-<work-item>-vm
   ```

5. After Copilot starts, change to the VM repository path returned by
   `sbx-host.inspect` or `sbx-host.seed`.
6. Have the VM agent read the repository's `AGENTS.md`, `README.md`, and
   package metadata to determine setup and validation commands.
   Seed creates user-local Corepack shims when Corepack is available, so
   repo-pinned Yarn and pnpm commands work without system installation.
7. Run repository-required rebuild, postinstall, code generation, or setup
   inside the VM after the seed restore, when the PAT is gone.
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
   - Call `sbx-host.sync` after host review/rebase.

12. After `sync`, rerun the repository-defined validation inside the VM.
13. Review the host worktree diff against the work item. Push only the expected
    `users/alwaibel/agent/<id>-<slug>` branch and create a draft PR.
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
- A reboot or daemon restart should not require recreating the sandbox.
- Interactive attachment always remains user-run from Windows Terminal; the
  host MCP bridge cannot proxy the VM's TTY.
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
`inspect`, `seed`, `export`, and `sync`; modifying tools require explicit
approval. Lifecycle, policy, diagnostics, and removal remain native `sbx`
operations run by the user from Windows Terminal.
