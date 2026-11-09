import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
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

  async function findActive(workItem) {
    await mkdir(tasksRoot, { recursive: true, mode: 0o700 });
    for (const name of await readdir(tasksRoot)) {
      if (!name.endsWith(".json")) continue;
      const task = await read(name.slice(0, -5));
      if (
        task.workItem === workItem &&
        ["queued", "running"].includes(task.status)
      ) {
        return task;
      }
    }
    return undefined;
  }

  async function dispatch(workItem, prompt) {
    const inspect = JSON.parse(await runHelper(["inspect", String(workItem)]));
    if (inspect.sandboxStatus !== "present") {
      throw new Error(`Sandbox is not ready: ${inspect.sandboxStatus}`);
    }
    const active = await findActive(workItem);
    if (active) {
      throw new Error(`Task ${active.taskId} is already active for this work item`);
    }

    const taskId = `task-${randomUUID()}`;
    const task = {
      taskId,
      workItem,
      sandbox: inspect.sandbox,
      repoDir: inspect.repoDir,
      status: "queued",
      createdAt: new Date().toISOString(),
    };
    await mkdir(tasksRoot, { recursive: true, mode: 0o700 });
    await writeFile(join(tasksRoot, `${taskId}.prompt`), prompt, { mode: 0o600 });
    await writeFile(join(tasksRoot, `${taskId}.log`), "", { mode: 0o600 });
    await writeJsonAtomic(join(tasksRoot, `${taskId}.json`), task);

    const child = spawn(
      "/usr/bin/bash",
      [helper, "dispatch", String(workItem), taskId],
      {
        cwd: home,
        detached: true,
        stdio: "ignore",
        env: {
          ...process.env,
          SBX_WORK_STATE_ROOT: stateRoot,
          SBX_WORK_TASKS_ROOT: tasksRoot,
        },
      },
    );
    await writeFile(join(tasksRoot, `${taskId}.pid`), `${child.pid}\n`, {
      mode: 0o600,
    });
    child.unref();
    return task;
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

  async function cancel(taskId) {
    const task = await read(taskId);
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

  return { cancel, dispatch, logs, read };
}
