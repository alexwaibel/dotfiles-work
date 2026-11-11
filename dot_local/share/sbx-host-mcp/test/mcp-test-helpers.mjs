import { spawn } from "node:child_process";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

export async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "sbx-host-mcp-"));
  const repos = join(root, "repos");
  const state = join(root, "state");
  const repo = join(repos, "example-repo");
  const helperLog = join(root, "helper.log");
  const helper = join(root, "helper.sh");
  await mkdir(join(repo, ".git"), { recursive: true });
  await mkdir(state, { recursive: true });
  await writeFile(
    join(state, "123.json"),
    JSON.stringify({
      workItem: "123",
      repo: "example-repo",
      sandbox: "wi-123-vm",
      privateValue: "must-not-leak",
    }),
  );
  await writeFile(
    helper,
    `#!/usr/bin/env bash
printf '%s\\n' "$*" >> ${JSON.stringify(helperLog)}
if [[ "$1" == "sync" && "$2" == "999" ]]; then
  printf 'x%.0s' {1..40000} >&2
  exit 1
fi
if [[ "$1" == "inspect" ]]; then
  printf '{"workItem":"123","sandbox":"wi-123-vm","repoDir":"/home/agent/workspace/example-repo","sandboxStatus":"present"}\n'
  exit 0
fi
if [[ "$1" == "dispatch" || "$1" == "run-job" ]]; then
  task="$SBX_WORK_STATE_ROOT/tasks/$3.json"
  log="$SBX_WORK_STATE_ROOT/tasks/$3.log"
  prompt="$SBX_WORK_STATE_ROOT/tasks/$3.prompt"
  tmp="$task.tmp"
  if [[ -f "$prompt" ]] && grep -q '^WAIT_QUEUED' "$prompt"; then
    sleep 5
  fi
  jq '.status = "running" | .runnerPid = $pid' --argjson pid "$$" "$task" >"$tmp"
  mv "$tmp" "$task"
  code=0
  if [[ "$(jq -r '.kind' "$task")" == "seed" ]]; then
    bash "$0" seed "$2" "$(jq -r '.seed.slug' "$task")" \
      "$(jq -r '.seed.repo' "$task")" \
      "$(jq -r '.seed.reuseExistingBranch' "$task")" >"$log" 2>&1
    code=$?
  else
    printf 'agent completed task\n' >"$log"
  fi
  jq '.status = (if $code == 0 then "completed" else "failed" end) | .exitCode = $code' --argjson code "$code" "$task" >"$tmp"
  mv "$tmp" "$task"
  exit 0
fi
if [[ "$1" == "seed" && "$3" == "slow-seed" ]]; then
  sleep 1
fi
if [[ "$1" == "seed" && "$3" == "failed-seed" ]]; then
  printf 'fixture seed failed\n' >&2
  exit 7
fi
printf 'helper: %s\\n' "$*"
`,
    { mode: 0o700 },
  );
  return { root, repos, state, helper, helperLog };
}

export function startServer(paths) {
  return spawn(process.execPath, ["server.mjs"], {
    cwd: new URL("..", import.meta.url),
    env: {
      ...process.env,
      SBX_HOST_REPOS_ROOT: paths.repos,
      SBX_HOST_STATE_ROOT: paths.state,
      SBX_HOST_HELPER: paths.helper,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
}

export function send(process, message) {
  process.stdin.write(`${JSON.stringify(message)}\n`);
}

export function readMessage(process) {
  return new Promise((resolve, reject) => {
    const onData = chunk => {
      for (const line of chunk.toString().split("\n")) {
        if (!line.trim()) continue;
        try {
          process.stdout.off("data", onData);
          resolve(JSON.parse(line));
          return;
        } catch {
          // Ignore non-JSON output.
        }
      }
    };
    process.stdout.on("data", onData);
    process.once("error", reject);
  });
}

export async function initialize(process) {
  send(process, {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "test", version: "1.0.0" },
    },
  });
  await readMessage(process);
  send(process, {
    jsonrpc: "2.0",
    method: "notifications/initialized",
    params: {},
  });
}
