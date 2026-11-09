import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
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
