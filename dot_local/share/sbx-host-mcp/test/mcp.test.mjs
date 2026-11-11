import assert from "node:assert/strict";
import { once } from "node:events";
import { join } from "node:path";
import { test } from "node:test";
import { createSandbox } from "../lib/sandbox.mjs";
import { createTaskManager } from "../lib/tasks.mjs";
import { writeJson } from "../lib/runtime.mjs";
import { fixture, startServer, waitForLog } from "./helpers.mjs";

test("MCP remains constrained, shares the real core, and preserves stdout despite native warnings", async t => {
  const paths = await fixture(t);
  const sandbox = createSandbox(paths.config);
  await sandbox.seed(123, { slug: "mcp", repo: "example-repo" });
  const state = await sandbox.inspect(123);
  await writeJson(join(paths.state, "123.json"), { ...state, privateValue: "must-not-leak" });
  paths.env.FAKE_SBX_WARNING = "1";
  const server = startServer(t, paths);
  await server.initialize();
  const tools = await server.request("tools/list", {});
  assert.deepEqual(tools.result.tools.map(tool => tool.name).sort(), [
    "cancel", "dispatch", "export", "inspect", "seed", "sync", "task_logs", "task_status",
  ]);
  const inspected = await server.call("inspect", { workItem: 123 });
  assert.equal(inspected.sandboxStatus, "present");
  assert.equal(inspected.privateValue, undefined);
  for (const [name, args] of [
    ["seed", { workItem: 123, slug: "../escape", repo: "example-repo" }],
    ["seed", { workItem: 123, slug: "valid", repo: ".." }],
    ["sync", { workItem: 123 }],
    ["sync", { workItem: 123, commit: "HEAD" }],
    ["task_status", { taskId: "../other" }],
    ["task_logs", { taskId: "task-11111111-1111-1111-1111-111111111111", tailBytes: 999999 }],
  ]) await assert.rejects(server.call(name, args));
  const started = await server.call("dispatch", { workItem: 123, prompt: "Read-only execution" });
  const tasks = createTaskManager(paths.config);
  assert.equal((await tasks.wait(started.taskId, 10000)).task.status, "completed");
  assert.equal((await server.call("task_status", { taskId: started.taskId })).status, "completed");
});

test("seed returns before long setup and survives MCP shutdown without a duplicate worker", async t => {
  const paths = await fixture(t);
  paths.env.FAKE_SBX_SLOW_CREATE = "1";
  const first = startServer(t, paths);
  await first.initialize();
  const started = await first.call("seed", { workItem: 123, slug: "slow", repo: "example-repo" });
  assert.equal(started.status, "running");
  const stopped = once(first.child, "close");
  first.child.kill();
  await stopped;
  const second = startServer(t, paths);
  await second.initialize();
  const reused = await second.call("seed", { workItem: 123, slug: "slow", repo: "example-repo" });
  assert.equal(reused.taskId, started.taskId);
  const tasks = createTaskManager(paths.config);
  assert.equal((await tasks.wait(started.taskId, 10000)).task.status, "completed");
  assert.equal((await second.call("inspect", { workItem: 123 })).sandboxStatus, "present");
});

test("Copilot survives MCP shutdown and a fresh client can cancel the VM task", async t => {
  const paths = await fixture(t);
  await createSandbox(paths.config).seed(123, { slug: "restart", repo: "example-repo" });
  const first = startServer(t, paths);
  await first.initialize();
  const running = await first.call("dispatch", { workItem: 123, prompt: "WAIT_RUNNING" });
  await waitForLog(paths, running.taskId, /agent-child=(\d+)/);
  const stopped = once(first.child, "close");
  first.child.kill();
  await stopped;
  const next = startServer(t, paths);
  await next.initialize();
  assert.equal((await next.call("task_status", { taskId: running.taskId })).status, "running");
  assert.equal((await next.call("cancel", { taskId: running.taskId })).status, "canceled");
});
