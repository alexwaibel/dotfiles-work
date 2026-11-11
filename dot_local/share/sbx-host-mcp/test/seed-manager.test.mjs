import assert from "node:assert/strict";
import { readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { createSeedManager } from "../lib/seed-manager.mjs";
import { createTaskManager } from "../lib/task-manager.mjs";
import { fixture } from "./mcp-test-helpers.mjs";

function managers(paths) {
  const taskManager = createTaskManager({
    helper: paths.helper,
    home: paths.root,
    reposRoot: paths.repos,
    stateRoot: paths.state,
    tasksRoot: join(paths.state, "tasks"),
    runHelper: async () => {
      throw new Error("seed must not use an in-memory helper promise");
    },
  });
  return { tasks: taskManager, seeds: createSeedManager({ taskManager }) };
}

test("seed survives manager recreation and reuses the event-driven task waiter", async t => {
  const paths = await fixture();
  t.after(() => rm(paths.root, { recursive: true, force: true }));
  const first = managers(paths);
  const started = await first.seeds.start(123, "slow-seed", "example-repo", false);
  const restarted = managers(paths);
  const duplicate = await restarted.seeds.start(
    123, "slow-seed", "example-repo", false,
  );
  assert.equal(duplicate.taskId, started.taskId);
  assert.equal((await restarted.seeds.wait(123, 0)).state, "running");
  await assert.rejects(
    restarted.seeds.start(123, "other-seed", "example-repo", false),
    /already active/,
  );
  await assert.rejects(
    restarted.tasks.dispatch(123, "Do not dispatch"), /already active/,
  );
  const { task, timedOut } = await restarted.tasks.wait(started.taskId, 5000);
  assert.equal(timedOut, false);
  assert.equal(task.status, "completed");
  assert.equal((await managers(paths).seeds.wait(123, 0)).state, "completed");
  const helperLog = await readFile(paths.helperLog, "utf8");
  assert.equal(
    helperLog.split("\n").filter(line => line.startsWith("seed 123 ")).length, 1,
  );
});

test("seed failure and logs survive restart and allow an explicit retry", async t => {
  const paths = await fixture();
  t.after(() => rm(paths.root, { recursive: true, force: true }));
  const first = managers(paths);
  const started = await first.seeds.start(123, "failed-seed", "example-repo", false);
  const failed = await first.tasks.wait(started.taskId, 5000);
  assert.equal(failed.task.exitCode, 7);
  const restarted = managers(paths);
  const result = await restarted.seeds.wait(123, 0);
  assert.equal(result.state, "failed");
  assert.match(result.error, /fixture seed failed/);
  const retry = await restarted.seeds.start(123, "retry", "example-repo", true);
  assert.notEqual(retry.taskId, started.taskId);
  assert.equal((await restarted.tasks.wait(retry.taskId, 5000)).task.status, "completed");
});
