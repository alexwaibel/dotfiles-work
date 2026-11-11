# Docker Sandbox bridge

`sbx-host` provides a limited mechanism for interacting with `sbx` to fire up
isolated sandboxed sessions without granting broad Windows executable or filesystem
access.

## What it does

- Creates, lists, stops, and removes VMs. New VMs have no host workspace mount,
  global shared-skills store, or external MCP access. A native kit seeds curated
  skills, model defaults, and coding instructions from shared chezmoi sources.
- Runs foreground commands inside a VM and returns their output and exit status.
  Backgrounding and log files are ordinary shell choices. Stop the VM to cancel work.
- Copies individual files through a bounded host staging directory,
  `~/repos/.sbx-transfer/` by default.
- Restores private dependencies using process-scoped Azure Artifacts
  credentials, with lifecycle scripts disabled.

The adapter handles Windows executable discovery and path translation.
Package authentication uses Windows AzureAuth; host Git operations use Linux Git.
