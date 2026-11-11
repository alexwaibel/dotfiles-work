import assert from "node:assert/strict";
import { readFile, readdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { createSandbox } from "../lib/sandbox.mjs";
import { createTaskManager } from "../lib/tasks.mjs";
import { processIdentity, writeJson } from "../lib/runtime.mjs";
import { fixture, waitForLog } from "./helpers.mjs";

test("seed survives manager recreation, reuses active work, and records failures without replacing old state", async t => {
  const paths = await fixture(t);
  paths.env.FAKE_SBX_SLOW_CREATE = "1";
  const tasks = createTaskManager(paths.config);
  const started = await tasks.startSeed(123, "slow-seed", "example-repo", false);
  const restarted = createTaskManager(paths.config);
  assert.equal((await restarted.startSeed(123, "slow-seed", "example-repo", false)).taskId, started.taskId);
  await assert.rejects(restarted.startSeed(123, "other", "example-repo", false), /already active/);
  await assert.rejects(restarted.dispatch(123, "Do not dispatch"), /already active/);
  await assert.rejects(restarted.export(123), /already active/);
  await assert.rejects(restarted.cancel(started.taskId), /Seed cancellation/);
  assert.equal((await restarted.wait(started.taskId, 10000)).task.status, "completed");
  assert.equal((await createTaskManager(paths.config).read(started.taskId)).status, "completed");
  delete paths.env.FAKE_SBX_SLOW_CREATE;
  paths.env.FAKE_SBX_FAIL = "bootstrap";
  const failed = await tasks.startSeed(124, "failed", "example-repo", false);
  const terminal = (await tasks.wait(failed.taskId, 10000)).task;
  assert.equal(terminal.status, "failed");
  assert.equal(terminal.exitCode, 7);
  assert.match(await tasks.logs(failed.taskId), /fixture seed failed/);
  delete paths.env.FAKE_SBX_FAIL;
  const retry = await tasks.startSeed(124, "retry", "example-repo", false);
  assert.equal((await tasks.wait(retry.taskId, 10000)).task.status, "completed");
});

test("dispatch has no prompt or PID sidecars and cancellation stops the VM task and its children", async t => {
  const paths = await fixture(t);
  const sandbox = createSandbox(paths.config);
  await sandbox.seed(123, { slug: "cancellation", repo: "example-repo" });
  const tasks = createTaskManager(paths.config);
  const started = await tasks.dispatch(123, "WAIT_RUNNING\nNever persist this prompt");
  assert.equal(started.status, "running");
  const [, childPid] = await waitForLog(paths, started.taskId, /agent-child=(\d+)/);
  assert.ok(await processIdentity(Number(childPid)));
  await assert.rejects(tasks.export(123), /already active/);
  await assert.rejects(tasks.sync(123, "a".repeat(40)), /already active/);
  const canceled = await tasks.cancel(started.taskId);
  assert.equal(canceled.status, "canceled");
  assert.equal(await processIdentity(Number(childPid)), undefined);
  const saved = await readFile(join(paths.config.tasksRoot, `${started.taskId}.json`), "utf8");
  assert.doesNotMatch(saved, /Never persist/);
  assert.deepEqual((await readdir(paths.config.tasksRoot)).filter(name => /\.(pid|prompt)$/.test(name)), []);
  const followup = await tasks.dispatch(123, "Read-only followup");
  assert.equal((await tasks.wait(followup.taskId, 10000)).task.status, "completed");
  assert.match(await tasks.logs(followup.taskId), /agent completed task/);
});

test("dead or reused worker PID is observational and never overwrites persisted history", async t => {
  const paths = await fixture(t);
  const id = "task-22222222-2222-2222-2222-222222222222";
  const file = join(paths.config.tasksRoot, `${id}.json`);
  const record = { taskId: id, workItem: 123, kind: "copilot", status: "running", runnerPid: process.pid, runnerIdentity: "previous-boot-or-process" };
  await writeJson(file, record);
  const tasks = createTaskManager(paths.config);
  assert.equal((await tasks.read(id)).status, "failed");
  assert.deepEqual(JSON.parse(await readFile(file, "utf8")), record);
  await assert.rejects(tasks.cancel(id), /not active/);
});

test("terminal status permits immediate follow-up even while the old worker is exiting", async t => {
  const paths = await fixture(t);
  await createSandbox(paths.config).seed(123, { slug: "completion", repo: "example-repo" });
  const preload = join(paths.root, "delayed-exit.mjs");
  await writeFile(preload, 'if (process.argv[1]?.endsWith("/worker.mjs")) process.once("beforeExit", () => setTimeout(() => {}, 1000));\n');
  paths.env.NODE_OPTIONS = `${paths.env.NODE_OPTIONS || ""} --import=${preload}`;
  const tasks = createTaskManager(paths.config);
  const first = await tasks.dispatch(123, "Finish before process exit");
  assert.equal((await tasks.wait(first.taskId, 10000)).task.status, "completed");
  assert.ok(await processIdentity(first.runnerPid));
  const next = await tasks.dispatch(123, "Start immediately after terminal status");
  assert.equal((await tasks.wait(next.taskId, 10000)).task.status, "completed");
});

test("independent work items do not contend on a global operation lock", async t => {
  const paths = await fixture(t);
  const sandbox = createSandbox(paths.config);
  await sandbox.seed(123, { slug: "first", repo: "example-repo" });
  await sandbox.seed(124, { slug: "second", repo: "example-repo" });
  const tasks = createTaskManager(paths.config);
  const running = await tasks.dispatch(123, "WAIT_RUNNING");
  await waitForLog(paths, running.taskId, /agent-child=(\d+)/);
  const independent = await tasks.dispatch(124, "Complete independently");
  assert.equal((await tasks.wait(independent.taskId, 10000)).task.status, "completed");
  assert.equal((await tasks.read(running.taskId)).status, "running");
  await tasks.cancel(running.taskId);
});
