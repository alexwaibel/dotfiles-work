import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { test } from "node:test";

async function fixture() {
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
if [[ "$1" == "dispatch" ]]; then
  task="$SBX_WORK_STATE_ROOT/tasks/$3.json"
  log="$SBX_WORK_STATE_ROOT/tasks/$3.log"
  prompt="$SBX_WORK_STATE_ROOT/tasks/$3.prompt"
  tmp="$task.tmp"
  if grep -q '^WAIT_QUEUED' "$prompt"; then
    sleep 5
  fi
  jq '.status = "running" | .runnerPid = $pid' --argjson pid "$$" "$task" >"$tmp"
  mv "$tmp" "$task"
  printf 'agent completed task\n' >"$log"
  jq '.status = "completed" | .exitCode = 0' "$task" >"$tmp"
  mv "$tmp" "$task"
  exit 0
fi
if [[ "$1" == "seed" && "$3" == "slow-seed" ]]; then
  sleep 1
fi
printf 'helper: %s\\n' "$*"
`,
    { mode: 0o700 },
  );
  return { root, repos, state, helper, helperLog };
}

function startServer(paths) {
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

function send(process, message) {
  process.stdin.write(`${JSON.stringify(message)}\n`);
}

function readMessage(process) {
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

async function initialize(process) {
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

test("lists the constrained tool surface", async t => {
  const paths = await fixture();
  const process = startServer(paths);
  t.after(() => process.kill());
  await initialize(process);
  send(process, { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
  const response = await readMessage(process);
  assert.deepEqual(
    response.result.tools.map(tool => tool.name).sort(),
    [
      "cancel",
      "dispatch",
      "export",
      "inspect",
      "seed",
      "sync",
      "task_logs",
      "task_status",
    ],
  );
});

test("inspect returns only allowlisted metadata", async t => {
  const paths = await fixture();
  const process = startServer(paths);
  t.after(() => process.kill());
  await initialize(process);
  send(process, {
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: { name: "inspect", arguments: { workItem: 123 } },
  });
  const response = await readMessage(process);
  const text = response.result.content[0].text;
  assert.match(text, /wi-123-vm/);
  assert.match(text, /"sandboxStatus":"present"/);
  assert.doesNotMatch(text, /must-not-leak/);
});

test("seed returns immediately and inspect waits for completion", async t => {
  const paths = await fixture();
  const process = startServer(paths);
  t.after(() => process.kill());
  await initialize(process);
  const started = Date.now();
  send(process, {
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: {
      name: "seed",
      arguments: {
        workItem: 123,
        slug: "slow-seed",
        repo: "example-repo",
      },
    },
  });
  const response = await readMessage(process);
  assert.equal(response.result.isError, undefined);
  assert.ok(Date.now() - started < 750);
  assert.match(response.result.content[0].text, /"seedStatus": "running"/);
  assert.doesNotMatch(response.result.content[0].text, /repoDir/);

  send(process, {
    jsonrpc: "2.0",
    id: 3,
    method: "tools/call",
    params: {
      name: "inspect",
      arguments: { workItem: 123, waitSeconds: 2 },
    },
  });
  const completed = await readMessage(process);
  assert.equal(completed.result.isError, undefined);
  assert.match(completed.result.content[0].text, /"sandboxStatus":"present"/);

  send(process, {
    jsonrpc: "2.0",
    id: 4,
    method: "tools/call",
    params: {
      name: "seed",
      arguments: {
        workItem: 123,
        slug: "../escape",
        repo: "example-repo",
      },
    },
  });
  const invalid = await readMessage(process);
  assert.equal(invalid.result.isError, true);
});

test("failed helper output is bounded", async t => {
  const paths = await fixture();
  const process = startServer(paths);
  t.after(() => process.kill());
  await initialize(process);

  send(process, {
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: { name: "sync", arguments: { workItem: 999 } },
  });
  const response = await readMessage(process);
  const text = response.result.content[0].text;
  assert.equal(response.result.isError, true);
  assert.match(text, /output truncated/);
  assert.ok(text.length < 34 * 1024);
});

test("dispatch persists status and logs", async t => {
  const paths = await fixture();
  const process = startServer(paths);
  t.after(() => process.kill());
  await initialize(process);

  send(process, {
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: {
      name: "dispatch",
      arguments: { workItem: 123, prompt: "Implement the bounded task." },
    },
  });
  const dispatched = await readMessage(process);
  assert.equal(dispatched.result.isError, undefined);
  const task = JSON.parse(dispatched.result.content[0].text);
  assert.match(task.taskId, /^task-[a-f0-9-]{36}$/);

  let status;
  for (let attempt = 0; attempt < 20; attempt += 1) {
    send(process, {
      jsonrpc: "2.0",
      id: 3 + attempt,
      method: "tools/call",
      params: {
        name: "task_status",
        arguments: { taskId: task.taskId },
      },
    });
    const response = await readMessage(process);
    status = JSON.parse(response.result.content[0].text);
    if (status.status === "completed") break;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  assert.equal(status.status, "completed");

  send(process, {
    jsonrpc: "2.0",
    id: 30,
    method: "tools/call",
    params: {
      name: "task_logs",
      arguments: { taskId: task.taskId },
    },
  });
  const logs = await readMessage(process);
  assert.match(logs.result.content[0].text, /agent completed task/);
});

test("cancel stops a task before queued dispatch starts", async t => {
  const paths = await fixture();
  const process = startServer(paths);
  t.after(() => process.kill());
  await initialize(process);

  send(process, {
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: {
      name: "dispatch",
      arguments: { workItem: 123, prompt: "WAIT_QUEUED\nDo not run." },
    },
  });
  const dispatched = await readMessage(process);
  const task = JSON.parse(dispatched.result.content[0].text);

  send(process, {
    jsonrpc: "2.0",
    id: 3,
    method: "tools/call",
    params: { name: "cancel", arguments: { taskId: task.taskId } },
  });
  const canceled = await readMessage(process);
  assert.equal(JSON.parse(canceled.result.content[0].text).status, "canceled");

  await new Promise(resolve => setTimeout(resolve, 200));
  send(process, {
    jsonrpc: "2.0",
    id: 4,
    method: "tools/call",
    params: {
      name: "task_status",
      arguments: { taskId: task.taskId },
    },
  });
  const status = await readMessage(process);
  assert.equal(JSON.parse(status.result.content[0].text).status, "canceled");
});

test("queued task with dead launcher becomes failed", async t => {
  const paths = await fixture();
  const tasks = join(paths.state, "tasks");
  await mkdir(tasks, { recursive: true });
  const taskId = "task-22222222-2222-2222-2222-222222222222";
  await writeFile(
    join(tasks, `${taskId}.json`),
    JSON.stringify({ taskId, workItem: 123, status: "queued" }),
  );
  await writeFile(join(tasks, `${taskId}.pid`), "2147483647\n");

  const process = startServer(paths);
  t.after(() => process.kill());
  await initialize(process);
  send(process, {
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: { name: "task_status", arguments: { taskId } },
  });
  const response = await readMessage(process);
  const task = JSON.parse(response.result.content[0].text);
  assert.equal(task.status, "failed");
  assert.match(task.error, /exited before starting/);
});
