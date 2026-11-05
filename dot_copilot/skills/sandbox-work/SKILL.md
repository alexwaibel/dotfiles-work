---
name: sandbox-work
description: Run an ADO coding task through an isolated Docker Sandbox VM using the sbx-work helper. Use when the user says "sandbox work item", "Docker sandbox workflow", "run this bug in sbx", or wants an autonomous implementation isolated from the host.
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
`sbx-host.ado_install` package-manager process. Lifecycle scripts are disabled
while that short-lived package-read PAT exists.

## Procedure

1. Fetch the complete ADO item and assess fitness.
2. Resolve unclear reproduction or design questions on the host.
3. Call `sbx-host.inspect` for the work-item ID:
   - If metadata exists, verify the repository, branch, base, and VM path, then
     resume that sandbox. Do not seed again.
   - If metadata is absent, identify the repository and slug, then call
     `sbx-host.seed`.
4. Ask the user to attach from Windows Terminal:

   ```powershell
   sbx run --name wi-<work-item>-vm
   ```

5. After Copilot starts, change to the VM repository path returned by
   `sbx-host.inspect` or `sbx-host.seed`.
6. Have the VM agent read the repository's `AGENTS.md`, `README.md`, and
   package metadata to determine setup and validation commands.
7. When a setup command needs Azure Artifacts authentication, run it from the
   trusted host without exposing the token to Copilot:

   Call `sbx-host.ado_install` with the package manager and install arguments.

   After `ado-install` returns and the PAT is gone, run any repository-required
   rebuild, postinstall, code generation, or setup command normally inside the
   VM.

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
- If Copilot reports expired or unauthorized credentials, ask the user to run:

  ```powershell
  gh auth status --hostname github.com
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
`inspect`, `seed`, `ado_install`, `export`, and `sync`; modifying tools require
explicit approval. The underlying `sbx-work` CLI remains an implementation
detail for bundle transfer and constrained Azure Artifacts package installation.
Lifecycle, policy, diagnostics, and removal remain native `sbx` operations.

## Local Copilot sandbox

Windows executables require WSL interop through `/init` and `/run/WSL`.
Granting those paths would let a sandboxed process launch arbitrary Windows
programs and would defeat the host filesystem boundary.

Use the unsandboxed, schema-constrained `sbx-host` MCP bridge for supported host
operations. Never add `/init`, `/run/WSL`, or broad `/mnt/c` access to the local
sandbox policy. Native lifecycle operations that the bridge does not expose
must be run by the user from Windows Terminal.
