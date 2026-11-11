import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { promisify } from "node:util";
import { createTaskManager } from "../lib/tasks.mjs";

const execute = promisify(execFile);
const taskId = "task-11111111-1111-1111-1111-111111111111";
const script = fileURLToPath(new URL("../cli.mjs", import.meta.url));

async function fixture(t, status = "running") {
  const tasksRoot = await mkdtemp(join(tmpdir(), "sbx-task-wait-"));
  t.after(() => rm(tasksRoot, { recursive: true, force: true }));
  const path = join(tasksRoot, `${taskId}.json`);
  const task = { taskId, status, runnerPid: process.pid };
  await writeFile(path, JSON.stringify(task));
  await writeFile(join(tasksRoot, `${taskId}.log`), "task result\n");
  return {
    tasksRoot,
    task,
    path,
    manager: createTaskManager({ tasksRoot }),
  };
}

async function replaceTask(path, task) {
  const temporary = `${path}.tmp`;
  await writeFile(temporary, JSON.stringify(task));
  await rename(temporary, path);
}

for (const status of ["completed", "failed", "canceled"]) {
  test(`wait observes atomic ${status} completion`, async t => {
    const { manager, task, path, tasksRoot } = await fixture(t);
    const waiting = manager.wait(taskId, 1000);
    await replaceTask(join(tasksRoot, "unrelated.json"), {
      ...task,
      status: "completed",
    });
    await replaceTask(path, { ...task, status: "running" });
    await replaceTask(path, { ...task, status });
    const result = await waiting;
    assert.equal(result.task.status, status);
    assert.equal(result.timedOut, false);
  });
}

test("wait returns an already finished task", async t => {
  const { manager } = await fixture(t, "completed");
  const result = await manager.wait(taskId, 1000);
  assert.equal(result.task.status, "completed");
  assert.equal(result.timedOut, false);
});

test("wait deadline leaves the task running", async t => {
  const { manager, path } = await fixture(t);
  const result = await manager.wait(taskId, 30);
  assert.equal(result.timedOut, true);
  assert.equal(result.task.status, "running");
  const persisted = JSON.parse(await readFile(path, "utf8"));
  assert.equal(persisted.status, "running");
  assert.equal(persisted.cancelRequested, undefined);
});

test("wait reports a runner that exited without recording completion", async t => {
  const { manager, path, task } = await fixture(t);
  await replaceTask(path, { ...task, runnerPid: 2147483647 });
  const result = await manager.wait(taskId, 1000);
  assert.equal(result.task.status, "failed");
  assert.match(result.task.error, /without recording completion/);
  assert.equal(result.timedOut, false);
  assert.equal(JSON.parse(await readFile(path, "utf8")).status, "running");
});

test("wait rejects missing task metadata", async t => {
  const { manager, path } = await fixture(t);
  await rm(path);
  await assert.rejects(manager.wait(taskId, 1000), { code: "ENOENT" });
});

for (const status of ["completed", "failed", "canceled", "running"]) {
  test(`CLI returns ${status} outcome and exits without a lingering watcher`, async t => {
    const { tasksRoot } = await fixture(t, status);
    const options = {
      env: { ...process.env, SBX_WORK_TASKS_ROOT: tasksRoot },
      timeout: 3000,
    };
    const command = execute(process.execPath, [script, "task-wait", taskId, "1"], options);
    let stdout;
    if (status === "completed") {
      ({ stdout } = await command);
    } else {
      await assert.rejects(command, error => {
        assert.equal(error.code, status === "running" ? 124 : 1);
        stdout = error.stdout;
        return true;
      });
    }
    const result = JSON.parse(stdout);
    assert.equal(result.task.status, status);
    assert.equal(result.timedOut, status === "running");
    assert.equal(
      result.logTail,
      status === "running" ? undefined : "task result\n",
    );
  });
}

test("CLI rejects task-path traversal and unbounded deadlines", async t => {
  const { tasksRoot } = await fixture(t);
  for (const [id, seconds] of [
    ["../other", "1"],
    [taskId, "0"],
    [taskId, "3601"],
  ]) {
    await assert.rejects(
      execute(process.execPath, [script, "task-wait", id, seconds], {
        env: { ...process.env, SBX_WORK_TASKS_ROOT: tasksRoot },
        timeout: 3000,
      }),
      { code: 1 },
    );
  }
});
