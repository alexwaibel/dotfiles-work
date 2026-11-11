---
name: sandbox-work
description: Run repository work or experiments in a Docker Sandbox VM. Gather context on the host, create a usable private checkout, run commands or Copilot, and retrieve results for review.
---

# Sandbox Work

Discuss the task and gather context through the host's ADO, Teams, browser, and
other tools. When useful, delegate a bounded task or experiment to a VM.
No work-item ID, prescribed branch, or publication workflow is required.

## Bridge

`sbx-host` is a thin Docker `sbx` bridge:

- `list`, `create`, `stop`, `remove`: native VM lifecycle.
- `exec(sandbox, cwd, script)`: run a foreground shell script **inside the VM**.
  Returns `output` and `exitCode`; check the exit code before claiming success.
  Redirect large output to a VM file instead of filling the response buffer.
- `copy(sandbox, direction, vmPath, file?)`: transfer one regular file.
  Host files are restricted to `~/repos/.sbx-transfer/`. Uploads name a staged
  file; downloads return a new local filename/path without overwriting files.
- `restore(sandbox, cwd, organization)`: private Yarn/npm/pnpm restore with
  process-scoped Azure Artifacts credentials and lifecycle scripts disabled.
  Runs in the foreground and returns `output` and `exitCode`.

`create` attaches the native kit at `~/.local/share/sbx-copilot-profile/`.
Chezmoi renders it from the same portable instructions and model defaults used
on the host, plus an allowlist of unchanged personal coding skills. Host hooks,
MCP configuration, credentials, and host-only instructions are not included.
The global Docker shared-skills store remains disabled.
New VMs get a profile snapshot; existing VMs are not updated automatically.
Keep task prompts about requirements rather than repeating these coding rules.

`create` makes a mountless Copilot VM without external MCPs.
No bridge operation fetches host Git, selects history, integrates changes, or
publishes. Windows executable/path handling stays inside the bridge.

## A simple starting recipe

1. Choose a descriptive VM name and call `create` (or reuse a VM from `list`).
2. Select the intended committed revision with ordinary Linux Git on the host.
   Stage a self-contained bundle in `~/repos/.sbx-transfer/`. For example:

   ```bash
   mkdir -p ~/repos/.sbx-transfer
   git -C /absolute/canonical/repo bundle create \
     ~/repos/.sbx-transfer/experiment.bundle HEAD
   ```

   `HEAD` is an example, not a default policy: fetch and select the task's
   revision first. Include the intended branch/ref, or use a temporary ref when
   selecting a detached SHA. Bundles do not include uncommitted or ignored files.
3. Use `copy` to send that file to `/tmp/seed.bundle`, then `exec` in `/tmp`:

   ```bash
   git clone /tmp/seed.bundle /tmp/repo
   git -C /tmp/repo remote remove origin
   ```

4. Read repository instructions and package metadata inside the VM. Set up
   the tools it actually needs. For Corepack projects, enable user-local shims:

   ```bash
   mkdir -p "$HOME/.local/bin"
   corepack enable --install-directory "$HOME/.local/bin"
   ```

   Commands receive `~/.local/bin` on PATH. Use `restore` for private Azure
   Artifacts dependencies; otherwise run the normal install in the VM. Run
   any required post-install setup separately, after private restore finishes.
5. Execute an experiment directly, or run `copilot --yolo -p '<bounded task>'`
   in the checkout. Include the relevant context, repository instructions,
   expected outcome, and validation requirements. Commit only when authorized.
   Do not include host credentials or unrelated conversation.
6. Retrieve the result in whatever form is useful: a file, patch, or Git bundle.
   For committed results, create a bundle in the VM, copy it back, and verify
   and fetch it using host Linux Git before reviewing. For example:

   ```bash
   git -C /absolute/canonical/repo bundle verify /returned/download/path
   git -C /absolute/canonical/repo fetch /returned/download/path \
     HEAD:refs/review/experiment
   ```

   Review and integrate in a host worktree under `~/repos/worktrees/`. Never
   edit the canonical clone. Publishing requires user authorization and follows
   repository instructions and the global External Artifact Hygiene policy.

## Optional background work

For long commands, explicitly background them through `exec`. For example:

```bash
job_dir="$(mktemp -d /tmp/sbx-work.XXXXXX)"
nohup bash -c '
  my_command
  code=$?
  printf "%s\n" "$code" > "$1/exit.tmp"
  mv "$1/exit.tmp" "$1/exit.code"
' bash "$job_dir" > "$job_dir/output.log" 2>&1 < /dev/null &
printf "%s\n" "$!" > "$job_dir/pid"
printf "%s\n" "$job_dir"
```

Replace `my_command` with the actual task. Record the returned directory and
its PID/log/exit-file paths. Later use ordinary `exec` calls to read
`exit.code` and a bounded log tail (`tail -c 32768`). A missing process or exit
file is not proof of success; work may have been interrupted. PID reuse is
possible, so do not kill a process based only on an old PID.
Private `restore` stays foreground; never acquire or save its token to build
your own background restore command.

Check after independent work or a meaningful wait; do not build tight
status-polling loops. To cancel work, stop the VM. **Killing the host `sbx exec`
client alone does not stop VM processes.** Native `exec` starts a stopped VM.
Remove a VM only after retrieving needed work.
Docker may reject a restart immediately after stopping while runtime files are
still being released; allow it to settle rather than recreating the VM.

Never pass Git-remote, ADO, Teams, mail, or deployment credentials into the VM.
Private package credentials are only for the bridge's constrained restore.
Keep live browser/external-system work on the host. Native `sbx` policy and
diagnostic commands remain available outside the command sandbox when needed.
If Copilot authentication expires, refresh the Docker-managed Copilot secret
using the user's GitHub authentication; do not copy credentials into prompts.
