import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { watch } from "node:fs";
import {
  mkdir,
  open,
  readFile,
  readdir,
  rename,
  stat,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";

export function createTaskManager({
  helper,
  home,
  reposRoot,
  stateRoot,
  tasksRoot,
  runHelper,
}) {
  async function writeJsonAtomic(path, value) {
    const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
    await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, {
      mode: 0o600,
    });
    await rename(temporary, path);
  }

  function processIsAlive(pid) {
    if (!Number.isInteger(pid) || pid <= 0) return false;
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  }

  async function read(taskId) {
    const path = join(tasksRoot, `${taskId}.json`);
    const task = JSON.parse(await readFile(path, "utf8"));
    if (task.status === "queued") {
      let launcherPid;
      try {
        launcherPid = Number.parseInt(
          await readFile(join(tasksRoot, `${taskId}.pid`), "utf8"),
          10,
        );
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
      if (Number.isInteger(launcherPid)) {
        task.runnerPid = launcherPid;
        if (!processIsAlive(launcherPid)) {
          task.status = "failed";
          task.error = "task runner exited before starting";
          task.completedAt = new Date().toISOString();
          await writeJsonAtomic(path, task);
        }
      }
    }
    if (task.status === "running" && !processIsAlive(task.runnerPid)) {
      task.status = "failed";
      task.error = "task runner exited without recording completion";
      task.completedAt = new Date().toISOString();
      await writeJsonAtomic(path, task);
    }
    return task;
  }

  async function find(workItem, { activeOnly = false, kind } = {}) {
    await mkdir(tasksRoot, { recursive: true, mode: 0o700 });
    let latest;
    for (const name of await readdir(tasksRoot)) {
      if (!name.endsWith(".json")) continue;
      const task = await read(name.slice(0, -5));
      if (
        task.workItem === workItem &&
        (!kind || task.kind === kind) &&
        (!activeOnly || ["queued", "running"].includes(task.status)) &&
        (!latest || task.createdAt > latest.createdAt)
      ) {
        latest = task;
      }
    }
    return latest;
  }

  async function launch(workItem, details, prompt) {
    const taskId = `task-${randomUUID()}`;
    const task = {
      taskId,
      workItem,
      ...details,
      status: "queued",
      createdAt: new Date().toISOString(),
    };
    await mkdir(tasksRoot, { recursive: true, mode: 0o700 });
    if (prompt !== undefined) {
      await writeFile(join(tasksRoot, `${taskId}.prompt`), prompt, { mode: 0o600 });
    }
    await writeFile(join(tasksRoot, `${taskId}.log`), "", { mode: 0o600 });
    await writeJsonAtomic(join(tasksRoot, `${taskId}.json`), task);

    const child = spawn(
      "/usr/bin/bash",
      [helper, "run-job", String(workItem), taskId],
      {
        cwd: home,
        detached: true,
        stdio: "ignore",
        env: {
          ...process.env,
          SBX_WORK_REPOS_ROOT:
            reposRoot || process.env.SBX_WORK_REPOS_ROOT || join(home, "repos"),
          SBX_WORK_STATE_ROOT: stateRoot,
          SBX_WORK_TASKS_ROOT: tasksRoot,
        },
      },
    );
    try {
      await new Promise((resolve, reject) => {
        child.once("spawn", resolve);
        child.once("error", reject);
      });
      await writeFile(join(tasksRoot, `${taskId}.pid`), `${child.pid}\n`, {
        mode: 0o600,
      });
    } catch (error) {
      task.status = "failed";
      task.error = error.message;
      task.completedAt = new Date().toISOString();
      await writeJsonAtomic(join(tasksRoot, `${taskId}.json`), task);
      throw error;
    }
    child.unref();
    return task;
  }

  async function dispatch(workItem, prompt) {
    const active = await find(workItem, { activeOnly: true });
    if (active) {
      throw new Error(`Task ${active.taskId} is already active for this work item`);
    }
    const inspect = JSON.parse(await runHelper(["inspect", String(workItem)]));
    if (inspect.sandboxStatus !== "present") {
      throw new Error(`Sandbox is not ready: ${inspect.sandboxStatus}`);
    }
    return launch(
      workItem,
      {
        kind: "copilot",
        sandbox: inspect.sandbox,
        repoDir: inspect.repoDir,
      },
      prompt,
    );
  }

  async function startSeed(workItem, slug, repo, reuseExistingBranch) {
    const active = await find(workItem, { activeOnly: true });
    if (active) {
      if (
        active.kind === "seed" &&
        active.seed.slug === slug &&
        active.seed.repo === repo &&
        active.seed.reuseExistingBranch === reuseExistingBranch
      ) {
        return active;
      }
      throw new Error(`Task ${active.taskId} is already active for this work item`);
    }
    return launch(workItem, {
      kind: "seed",
      sandbox: `wi-${workItem}-vm`,
      seed: { slug, repo, reuseExistingBranch },
    });
  }

  async function logs(taskId, tailBytes) {
    await read(taskId);
    const path = join(tasksRoot, `${taskId}.log`);
    const metadata = await stat(path);
    const length = Math.min(metadata.size, tailBytes);
    const handle = await open(path, "r");
    try {
      const buffer = Buffer.alloc(length);
      await handle.read(buffer, 0, length, metadata.size - length);
      return buffer.toString("utf8");
    } finally {
      await handle.close();
    }
  }

  function wait(taskId, timeoutMs) {
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 3600000) {
      throw new Error("Wait timeout must be between 1 ms and 1 hour");
    }
    return new Promise((resolve, reject) => {
      let finished = false;
      let timer;
      // Task metadata is atomically replaced, so watch its directory.
      const watcher = watch(tasksRoot, (_event, filename) => {
        if (
          !filename ||
          filename === `${taskId}.json` ||
          filename === `${taskId}.pid`
        ) {
          check().catch(fail);
        }
      });

      function finish(error, value) {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        watcher.close();
        if (error) reject(error);
        else resolve(value);
      }

      function fail(error) {
        finish(error);
      }

      async function check(deadlineReached = false) {
        if (finished) return;
        const task = await read(taskId);
        const active = ["queued", "running"].includes(task.status);
        if (!active || deadlineReached) {
          finish(undefined, { task, timedOut: active });
        }
      }

      watcher.on("error", fail);
      timer = setTimeout(() => check(true).catch(fail), timeoutMs);
      check().catch(fail);
    });
  }

  async function cancel(taskId) {
    const task = await read(taskId);
    if (task.kind === "seed") {
      throw new Error("Seed cancellation requires native Docker lifecycle recovery");
    }
    if (!["queued", "running"].includes(task.status)) {
      throw new Error(`Task is not active: ${task.status}`);
    }
    let runnerPid = task.runnerPid;
    if (!Number.isInteger(runnerPid)) {
      try {
        runnerPid = Number.parseInt(
          await readFile(join(tasksRoot, `${taskId}.pid`), "utf8"),
          10,
        );
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
    }
    if (processIsAlive(runnerPid)) {
      try {
        process.kill(-runnerPid, "SIGTERM");
      } catch (error) {
        if (error?.code !== "ESRCH") throw error;
      }
    }
    task.status = "canceled";
    task.cancelRequested = true;
    task.completedAt = new Date().toISOString();
    await writeJsonAtomic(join(tasksRoot, `${taskId}.json`), task);
    return task;
  }

  return { cancel, dispatch, find, logs, read, startSeed, wait };
}
