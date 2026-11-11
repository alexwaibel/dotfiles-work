import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { watch } from "node:fs";
import {
  mkdir,
  open,
  readFile,
  readdir,
  stat,
} from "node:fs/promises";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";

export function createTaskManager({
  helper,
  home,
  reposRoot,
  stateRoot,
  tasksRoot,
  runHelper,
}) {
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
    const task = JSON.parse(
      await readFile(join(tasksRoot, `${taskId}.json`), "utf8"),
    );
    if (task.status === "running" && !processIsAlive(task.runnerPid)) {
      return {
        ...task,
        status: "failed",
        error: "task runner exited without recording completion",
      };
    }
    return task;
  }

  async function find(workItem, { kind } = {}) {
    await mkdir(tasksRoot, { recursive: true, mode: 0o700 });
    for (const name of await readdir(tasksRoot)) {
      if (!name.endsWith(".json")) continue;
      const task = await read(name.slice(0, -5));
      if (
        task.workItem === workItem &&
        (!kind || task.kind === kind) &&
        task.status === "running"
      ) {
        return task;
      }
    }
  }

  async function launch(workItem, details, prompt) {
    const taskId = `task-${randomUUID()}`;
    const task = {
      taskId,
      workItem,
      ...details,
      createdAt: new Date().toISOString(),
    };
    await mkdir(tasksRoot, { recursive: true, mode: 0o700 });
    const log = await open(join(tasksRoot, `${taskId}.log`), "w", 0o600);
    try {
      const child = spawn(
        "/usr/bin/bash",
        [join(dirname(helper), "run-task.sh"), String(workItem), taskId],
        {
          cwd: home,
          detached: true,
          stdio: ["pipe", "pipe", log.fd],
          env: {
            ...process.env,
            SBX_WORK_REPOS_ROOT:
              reposRoot || process.env.SBX_WORK_REPOS_ROOT || join(home, "repos"),
            SBX_WORK_STATE_ROOT: stateRoot,
            SBX_WORK_TASKS_ROOT: tasksRoot,
          },
        },
      );
      const ready = createInterface({ input: child.stdout });
      const started = new Promise((resolve, reject) => {
        ready.once("line", line => {
          try {
            resolve(JSON.parse(line));
          } catch (error) {
            reject(error);
          }
        });
        child.once("error", reject);
        child.once("exit", code => reject(
          new Error(`Task ${taskId} exited before startup (${code}); see its log`),
        ));
        child.stdin.on("error", reject);
      });
      child.stdin.end(JSON.stringify({ ...task, prompt }));
      try {
        return await started;
      } finally {
        ready.close();
        child.stdout.destroy();
        child.unref();
      }
    } finally {
      await log.close();
    }
  }

  async function dispatch(workItem, prompt) {
    const active = await find(workItem);
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
    const active = await find(workItem);
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
          filename === `${taskId}.json`
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
        const active = task.status === "running";
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
    if (task.status !== "running") {
      throw new Error(`Task is not active: ${task.status}`);
    }
    try {
      process.kill(-task.runnerPid, "SIGTERM");
    } catch (error) {
      if (error?.code !== "ESRCH") throw error;
    }
    return (await wait(taskId, 5000)).task;
  }

  return { cancel, dispatch, find, logs, read, startSeed, wait };
}
