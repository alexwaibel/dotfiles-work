import assert from "node:assert/strict";
import { once } from "node:events";
import { readFile, rm } from "node:fs/promises";
import { test } from "node:test";
import { join } from "node:path";
import { createTaskManager } from "../lib/task-manager.mjs";
import {
  fixture,
  initialize,
  readMessage,
  send,
  startServer,
} from "./mcp-test-helpers.mjs";

function tasks(paths) {
  return createTaskManager({ tasksRoot: join(paths.state, "tasks") });
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

test("seed returns immediately and uses the single task completion waiter", async t => {
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
  const task = JSON.parse(response.result.content[0].text);
  assert.match(task.taskId, /^task-/);
  assert.doesNotMatch(response.result.content[0].text, /repoDir/);

  assert.equal((await tasks(paths).wait(task.taskId, 5000)).task.status, "completed");
  send(process, {
    jsonrpc: "2.0",
    id: 3,
    method: "tools/call",
    params: {
      name: "inspect",
      arguments: { workItem: 123 },
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
        workItem: 124,
        slug: "follow-up",
        repo: "example-repo",
        reuseExistingBranch: true,
      },
    },
  });
  const followUp = await readMessage(process);
  assert.equal(followUp.result.isError, undefined);
  const followUpTask = JSON.parse(followUp.result.content[0].text);
  assert.equal((await tasks(paths).wait(followUpTask.taskId, 5000)).task.status, "completed");

  send(process, {
    jsonrpc: "2.0",
    id: 5,
    method: "tools/call",
    params: {
      name: "inspect",
      arguments: { workItem: 124 },
    },
  });
  const followUpCompleted = await readMessage(process);
  assert.equal(followUpCompleted.result.isError, undefined);

  const helperLog = await readFile(paths.helperLog, "utf8");
  assert.match(helperLog, /^seed 123 slow-seed example-repo false$/m);
  assert.match(helperLog, /^seed 124 follow-up example-repo true$/m);

  send(process, {
    jsonrpc: "2.0",
    id: 6,
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
    params: { name: "sync", arguments: { workItem: 999, commit: "a".repeat(40) } },
  });
  const response = await readMessage(process);
  const text = response.result.content[0].text;
  assert.equal(response.result.isError, true);
  assert.match(text, /output truncated/);
  assert.ok(text.length < 34 * 1024);
});

test("sync requires and forwards an explicit full commit SHA", async t => {
  const paths = await fixture();
  const process = startServer(paths);
  t.after(() => process.kill());
  await initialize(process);
  send(process, {
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: { name: "sync", arguments: { workItem: 123 } },
  });
  assert.equal((await readMessage(process)).result.isError, true);
  const commit = "b".repeat(40);
  send(process, {
    jsonrpc: "2.0", id: 3, method: "tools/call",
    params: { name: "sync", arguments: { workItem: 123, commit } },
  });
  assert.equal((await readMessage(process)).result.isError, undefined);
  assert.match(await readFile(paths.helperLog, "utf8"), new RegExp(`^sync 123 ${commit}$`, "m"));
});

test("seed runner survives an MCP server restart", async t => {
  const paths = await fixture();
  const first = startServer(paths);
  t.after(() => first.kill());
  await initialize(first);
  send(first, {
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: {
      name: "seed",
      arguments: { workItem: 123, slug: "slow-seed", repo: "example-repo" },
    },
  });
  const started = await readMessage(first);
  const { taskId } = JSON.parse(started.result.content[0].text);
  assert.match(taskId, /^task-[a-f0-9-]{36}$/);
  const stopped = once(first, "exit");
  first.kill();
  await stopped;

  const restarted = startServer(paths);
  t.after(() => restarted.kill());
  await initialize(restarted);
  assert.equal((await tasks(paths).wait(taskId, 5000)).task.status, "completed");
  send(restarted, {
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: { name: "inspect", arguments: { workItem: 123 } },
  });
  const inspected = await readMessage(restarted);
  assert.equal(inspected.result.isError, undefined);
  assert.match(inspected.result.content[0].text, /"sandboxStatus":"present"/);
  send(restarted, {
    jsonrpc: "2.0", id: 3, method: "tools/call",
    params: { name: "task_status", arguments: { taskId } },
  });
  const status = await readMessage(restarted);
  assert.equal(JSON.parse(status.result.content[0].text).status, "completed");
  const log = await readFile(paths.helperLog, "utf8");
  assert.equal(
    log.split("\n").filter(line => line.startsWith("seed 123 ")).length, 1,
  );
  await rm(paths.root, { recursive: true, force: true });
});
