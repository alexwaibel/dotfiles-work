import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { createTaskManager } from "../lib/task-manager.mjs";
import {
  fixture,
  initialize,
  readMessage,
  send,
  startServer,
} from "./mcp-test-helpers.mjs";

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
  assert.equal(task.status, "running");
  assert.equal(
    (await readdir(join(paths.state, "tasks"))).some(name => /\.(pid|prompt)$/.test(name)),
    false,
  );
  assert.doesNotMatch(await readFile(join(paths.state, "tasks", `${task.taskId}.json`), "utf8"), /Implement the bounded/);

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

test("cancel observes the worker's terminal status", async t => {
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
      arguments: { workItem: 123, prompt: "WAIT_RUNNING\nWait for cancellation." },
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

test("dead worker is reported without modifying its persisted record", async t => {
  const paths = await fixture();
  const tasks = join(paths.state, "tasks");
  await mkdir(tasks, { recursive: true });
  const taskId = "task-22222222-2222-2222-2222-222222222222";
  const record = JSON.stringify({ taskId, workItem: 123, status: "running", runnerPid: 2147483647 });
  await writeFile(join(tasks, `${taskId}.json`), record);

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
  assert.match(task.error, /without recording completion/);
  assert.equal(await readFile(join(tasks, `${taskId}.json`), "utf8"), record);
});

test("the real worker records cancellation without prompt or PID sidecars", async t => {
  const paths = await fixture();
  const tasksRoot = join(paths.state, "tasks");
  const fakeSbx = join(paths.root, "sbx");
  const taskId = "task-33333333-3333-3333-3333-333333333333";
  await writeFile(fakeSbx, "#!/usr/bin/env bash\ncat >/dev/null\nexec sleep 30\n", { mode: 0o700 });
  await writeFile(join(paths.state, "123.json"), JSON.stringify({
    sandbox: "wi-123-vm", repoDir: paths.root,
  }));
  const worker = spawn("bash", [
    fileURLToPath(new URL("../run-task.sh", import.meta.url)), "123", taskId,
  ], {
    detached: true,
    env: { ...process.env, SBX_WORK_STATE_ROOT: paths.state, SBX_WORK_SBX_BIN: fakeSbx },
    stdio: ["pipe", "pipe", "ignore"],
  });
  t.after(async () => {
    if (worker.exitCode === null && worker.signalCode === null) {
      try { process.kill(-worker.pid, "SIGTERM"); } catch (error) {
        if (error.code !== "ESRCH") throw error;
      }
    }
    await rm(paths.root, { recursive: true, force: true });
  });
  const ready = createInterface({ input: worker.stdout });
  const started = once(ready, "line", { signal: AbortSignal.timeout(3000) });
  worker.stdin.end(JSON.stringify({
    taskId, workItem: 123, kind: "copilot", prompt: "Do not persist this prompt",
  }));
  const [line] = await started;
  assert.equal(JSON.parse(line).runnerPid, worker.pid);
  ready.close();
  worker.stdout.destroy();
  const tasks = createTaskManager({ tasksRoot });
  assert.equal((await tasks.cancel(taskId)).status, "canceled");
  const persisted = JSON.parse(await readFile(join(tasksRoot, `${taskId}.json`), "utf8"));
  assert.equal(persisted.status, "canceled");
  assert.ok(persisted.completedAt);
  assert.equal(persisted.prompt, undefined);
  assert.deepEqual((await readdir(tasksRoot)).filter(name => /\.(pid|prompt)$/.test(name)), []);
});

test("dispatch reports a worker that fails before its startup acknowledgement", async t => {
  const paths = await fixture();
  t.after(() => rm(paths.root, { recursive: true, force: true }));
  await writeFile(join(paths.root, "run-task.sh"), "#!/usr/bin/env bash\necho startup-failed >&2\nexit 7\n");
  const tasks = createTaskManager({
    helper: paths.helper,
    home: paths.root,
    reposRoot: paths.repos,
    stateRoot: paths.state,
    tasksRoot: join(paths.state, "tasks"),
    runHelper: async () => JSON.stringify({ sandboxStatus: "present" }),
  });
  await assert.rejects(tasks.dispatch(123, "Never starts"), /exited before startup \(7\)/);
  const [log] = await readdir(join(paths.state, "tasks"));
  assert.match(await tasks.logs(log.slice(0, -4), 1024), /startup-failed/);
});
