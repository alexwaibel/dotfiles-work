#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034

set -euo pipefail

readonly PROGRAM="${0##*/}"
readonly DEFAULT_REPOS_ROOT="${HOME}/repos"
readonly DEFAULT_STATE_ROOT="${XDG_STATE_HOME:-${HOME}/.local/state}/sbx-work"

repos_root="${SBX_WORK_REPOS_ROOT:-$DEFAULT_REPOS_ROOT}"
state_root="${SBX_WORK_STATE_ROOT:-$DEFAULT_STATE_ROOT}"
tasks_root="${SBX_WORK_TASKS_ROOT:-${state_root}/tasks}"
dry_run=false

usage() {
  cat <<'EOF'
Usage:
  sbx-work inspect WORK_ITEM
  sbx-work [--dry-run] seed WORK_ITEM SLUG REPO [REUSE_EXISTING_BRANCH]
  sbx-work task-wait TASK_ID [TIMEOUT_SECONDS]
  sbx-work [--dry-run] export WORK_ITEM
  sbx-work [--dry-run] sync WORK_ITEM COMMIT

Commands:
  inspect   Report transfer metadata and whether its sandbox still exists.
  seed      Create a native clone-mode sandbox, create the task branch, and
            restore detected Azure Artifacts dependencies before agent startup.
  task-wait Wait locally for task completion (default 1800s, maximum 3600s).
  export    Verify and import the exact VM commit; leave host branches unchanged.
  sync      Transfer an explicit full commit SHA into the clean VM checkout.

Start coding tasks through sbx-host.dispatch. The subprocess runner is private.
Use ordinary host Git commands to review and integrate imported refs.

Use native sbx commands for everything else:
  sbx run --name wi-<id>-vm
  sbx ls
  sbx policy allow network --sandbox wi-<id>-vm <rule>
  sbx stop wi-<id>-vm
  sbx rm wi-<id>-vm

REPO defaults to the current Git repository name. Postinstall, rebuild, setup,
test, and validation commands remain the coding agent's responsibility.
EOF
}


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/sbx-adapter.sh
source "$SCRIPT_DIR/lib/sbx-adapter.sh"
# shellcheck source=lib/package-auth.sh
source "$SCRIPT_DIR/lib/package-auth.sh"
# shellcheck source=commands/seed.sh
source "$SCRIPT_DIR/commands/seed.sh"
# shellcheck source=commands/transfer.sh
source "$SCRIPT_DIR/commands/transfer.sh"
while (($#)); do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

command_name="${1:-}"
[[ -n "$command_name" ]] || {
  usage
  exit 2
}
shift

case "$command_name" in
  inspect)
    (($# == 1)) || die "inspect requires WORK_ITEM"
    acquire_lock
    inspect_work "$1"
    ;;
  seed)
    (($# >= 3 && $# <= 4)) ||
      die "seed requires WORK_ITEM SLUG REPO [REUSE_EXISTING_BRANCH]"
    acquire_lock
    seed "$@"
    ;;
  task-wait)
    (($# >= 1 && $# <= 2)) || die "task-wait requires TASK_ID [TIMEOUT_SECONDS]"
    validate_task_id "$1"
    exec node "$SCRIPT_DIR/task-wait.mjs" "$tasks_root" "$@"
    ;;
  export)
    (($# == 1)) || die "export requires WORK_ITEM"
    acquire_lock
    export_work "$1"
    ;;
  sync)
    (($# == 2)) || die "sync requires WORK_ITEM COMMIT"
    acquire_lock
    sync_work "$1" "$2"
    ;;
  *)
    die "unknown command: $command_name"
    ;;
esac
