import assert from "node:assert/strict";
import { readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { createTaskManager } from "../lib/task-manager.mjs";
import { fixture } from "./mcp-test-helpers.mjs";

function manager(paths) {
  return createTaskManager({
    helper: paths.helper,
    home: paths.root,
    reposRoot: paths.repos,
    stateRoot: paths.state,
    tasksRoot: join(paths.state, "tasks"),
    runHelper: async () => {
      throw new Error("seed must not use an in-memory helper promise");
    },
  });
}

test("seed survives manager recreation and reuses the event-driven task waiter", async t => {
  const paths = await fixture();
  t.after(() => rm(paths.root, { recursive: true, force: true }));
  const first = manager(paths);
  const started = await first.startSeed(123, "slow-seed", "example-repo", false);
  const restarted = manager(paths);
  const duplicate = await restarted.startSeed(
    123, "slow-seed", "example-repo", false,
  );
  assert.equal(duplicate.taskId, started.taskId);
  await assert.rejects(
    restarted.startSeed(123, "other-seed", "example-repo", false),
    /already active/,
  );
  await assert.rejects(
    restarted.dispatch(123, "Do not dispatch"), /already active/,
  );
  const { task, timedOut } = await restarted.wait(started.taskId, 5000);
  assert.equal(timedOut, false);
  assert.equal(task.status, "completed");
  assert.equal((await manager(paths).read(started.taskId)).status, "completed");
  const helperLog = await readFile(paths.helperLog, "utf8");
  assert.equal(
    helperLog.split("\n").filter(line => line.startsWith("seed 123 ")).length, 1,
  );
});

test("seed failure and logs survive restart and allow an explicit retry", async t => {
  const paths = await fixture();
  t.after(() => rm(paths.root, { recursive: true, force: true }));
  const first = manager(paths);
  const started = await first.startSeed(123, "failed-seed", "example-repo", false);
  const failed = await first.wait(started.taskId, 5000);
  assert.equal(failed.task.exitCode, 7);
  const restarted = manager(paths);
  assert.equal((await restarted.read(started.taskId)).status, "failed");
  assert.match(await restarted.logs(started.taskId, 16384), /fixture seed failed/);
  const retry = await restarted.startSeed(123, "retry", "example-repo", true);
  assert.notEqual(retry.taskId, started.taskId);
  assert.equal((await restarted.wait(retry.taskId, 5000)).task.status, "completed");
});
