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
Azure Artifacts credentials may be passed only to the constrained
`sbx-work ado-install` package-manager process. Lifecycle scripts are disabled
while that short-lived package-read PAT exists.

## Procedure

1. Fetch the complete ADO item and assess fitness before creating a sandbox.
2. Resolve unclear reproduction or design questions on the host.
3. Run:

   ```bash
   sbx-work seed <work-item> <slug> <repo>
   sbx run --name wi-<work-item>-vm
   ```

4. After Copilot starts, change to the path printed by `sbx-work seed`.
5. Have the VM agent read the repository's `AGENTS.md`, `README.md`, and
   package metadata to determine setup and validation commands.
6. When a setup command needs Azure Artifacts authentication, run it from the
   trusted host without exposing the token to Copilot:

   ```bash
   sbx-work ado-install <work-item> -- <package-manager> [install-args...]
   ```

   After `ado-install` returns and the PAT is gone, run any repository-required
   rebuild, postinstall, code generation, or setup command normally inside the
   VM.

7. If Balanced networking blocks a required package or API host, inspect the
   Docker policy log and add only the required sandbox-scoped rule:

   ```bash
   sbx policy allow network --sandbox wi-<work-item>-vm '<host-rule>'
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
   sbx-work export <work-item>
   sbx-work sync <work-item>
   ```

11. After `sync`, rerun the repository-defined validation inside the VM.
12. Review the host worktree diff against the work item. Push only the expected
    `users/alwaibel/agent/<id>-<slug>` branch and create a draft PR.
13. Stop the VM for PR follow-up using Docker directly:

   ```bash
   sbx stop wi-<work-item>-vm
   ```

14. Remove it only after all VM commits are exported:

    ```bash
    sbx rm wi-<work-item>-vm
    ```

## Recovery

- Transfer metadata is stored under `~/.local/state/sbx-work/`.
- A reboot or daemon restart should not require recreating the sandbox.
- If export or synchronization fails, keep both the VM and host worktree. Do not
  delete state or bypass bundle verification.
- Before running `sbx rm`, confirm the VM is clean and its HEAD matches the
  exported or synchronized host commit.

## Repository behavior

`sbx-work` is only a compatibility shim for WSL bundle transfer and constrained,
process-scoped Azure Artifacts package installation. Lifecycle, policy,
diagnostics, and status remain native `sbx` operations.

## Local Copilot sandbox

Windows executables require WSL interop through `/init` and `/run/WSL`.
Granting those paths would let a sandboxed process launch arbitrary Windows
programs and would defeat the host filesystem boundary.

Run `sbx-work` and native `sbx.exe` operations through an explicit Copilot
sandbox-bypass approval. Never add `/init`, `/run/WSL`, or broad `/mnt/c`
access to the local sandbox policy. If a command fails with `cannot execute:
required file not found`, request a bypass for that exact command instead of
changing filesystem grants.
