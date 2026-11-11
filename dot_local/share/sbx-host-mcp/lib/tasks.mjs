import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { closeSync, openSync, watch } from "node:fs";
import { mkdir, open, readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalRepo, configuration, formatError, processIdentity, readJson, taskId, workItem } from "./runtime.mjs";

const worker = fileURLToPath(new URL("../worker.mjs", import.meta.url));

export function createTaskManager(options = {}) {
  const config = configuration(options);
  const path = id => join(config.tasksRoot, `${taskId(id)}.json`);

  async function read(id) {
    const task = await readJson(path(id));
    if (task.status === "running") {
      const identity = await processIdentity(task.runnerPid);
      if (!identity || (task.runnerIdentity && task.runnerIdentity !== identity)) {
        return { ...task, status: "failed", error: "task runner exited without recording completion" };
      }
    }
    return task;
  }

  async function find(id, { kind } = {}) {
    await mkdir(config.tasksRoot, { recursive: true, mode: 0o700 });
    for (const name of await readdir(config.tasksRoot)) {
      if (!/^task-[a-f0-9-]{36}\.json$/.test(name)) continue;
      const task = await read(name.slice(0, -5));
      if (Number(task.workItem) === workItem(id) && (!kind || task.kind === kind) && task.status === "running") return task;
    }
  }

  async function launch(request, background = false) {
    request.workItem = workItem(request.workItem);
    await mkdir(config.stateRoot, { recursive: true, mode: 0o700 });
    let log, lock;
    if (background) {
      request.taskId = `task-${randomUUID()}`;
      await mkdir(config.tasksRoot, { recursive: true, mode: 0o700 });
      log = await open(join(config.tasksRoot, `${request.taskId}.log`), "w", 0o600);
    }
    try {
      lock = openSync(join(config.stateRoot, `work-${request.workItem}.lock`), "a", 0o600);
      // fd 3 carries Node IPC; fd 4 keeps the lock under explicit worker ownership.
      const child = spawn(process.execPath, [worker], {
        cwd: config.home, detached: background,
        stdio: ["ignore", log?.fd ?? "ignore", log?.fd ?? "pipe", "ipc", lock],
        env: {
          ...config.env, SBX_HOST_REPOS_ROOT: config.reposRoot,
          SBX_HOST_STATE_ROOT: config.stateRoot, SBX_WORK_TASKS_ROOT: config.tasksRoot,
        },
      });
      closeSync(lock);
      lock = undefined;
      let stderr = "", response;
      child.stderr?.on("data", chunk => { stderr = (stderr + chunk).slice(-32768); });
      return await new Promise((resolve, reject) => {
        child.once("error", reject);
        child.on("message", message => {
          response = message;
          if (background && message.result) { child.unref(); resolve(message.result); }
        });
        child.once("close", code => {
          if (response?.error) reject(new Error(response.error));
          else if (response?.result) resolve(response.result);
          else reject(new Error(code === 73 ? "Another operation is already active for this work item" :
            `Task ${request.taskId || request.kind} exited before startup (${code}); ${stderr || "see its log"}`));
        });
        child.send(request, error => { if (error) reject(error); });
      });
    } finally {
      if (lock !== undefined) closeSync(lock);
      await log?.close();
    }
  }

  async function dispatch(id, prompt) {
    if (typeof prompt !== "string" || !prompt.length || prompt.length > 32000) throw new Error("invalid prompt");
    const active = await find(id);
    if (active) throw new Error(`Task ${active.taskId} is already active for this work item`);
    return launch({ workItem: id, kind: "copilot", prompt }, true);
  }

  async function startSeed(id, slug, repo, reuseExistingBranch = false) {
    if (!/^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?$/.test(slug)) throw new Error("invalid slug");
    await canonicalRepo(config, repo);
    const active = await find(id);
    if (active) {
      if (active.kind === "seed" && active.seed.slug === slug && active.seed.repo === repo &&
          active.seed.reuseExistingBranch === reuseExistingBranch) return active;
      throw new Error(`Task ${active.taskId} is already active for this work item`);
    }
    return launch({ workItem: id, kind: "seed", seed: { slug, repo, reuseExistingBranch } }, true);
  }

  async function logs(id, tailBytes = 16384) {
    const file = join(config.tasksRoot, `${taskId(id)}.log`);
    const metadata = await stat(file);
    const length = Math.min(metadata.size, tailBytes);
    const handle = await open(file, "r");
    try {
      const buffer = Buffer.alloc(length);
      await handle.read(buffer, 0, length, metadata.size - length);
      return buffer.toString("utf8");
    } finally { await handle.close(); }
  }

  function wait(id, timeoutMs) {
    taskId(id);
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 3600000) throw new Error("Wait timeout must be between 1 ms and 1 hour");
    return new Promise((resolve, reject) => {
      let finished = false, timer;
      const finish = (error, value) => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        watcher.close();
        if (error) reject(error); else resolve(value);
      };
      const check = async (deadline = false) => {
        if (finished) return;
        const task = await read(id);
        if (task.status !== "running" || deadline) finish(undefined, { task, timedOut: task.status === "running" });
      };
      // Atomic replacement changes the inode, so observe the directory.
      const watcher = watch(config.tasksRoot, (_event, file) => {
        if (!file || file === `${id}.json`) check().catch(finish);
      });
      watcher.on("error", finish);
      timer = setTimeout(() => check(true).catch(finish), timeoutMs);
      check().catch(finish);
    });
  }

  async function cancel(id) {
    const task = await read(id);
    if (task.kind === "seed") throw new Error("Seed cancellation requires native Docker lifecycle recovery");
    if (task.status !== "running") throw new Error(`Task is not active: ${task.status}`);
    try { process.kill(task.runnerPid, "SIGTERM"); }
    catch (error) { if (error.code !== "ESRCH") throw error; }
    const result = await wait(id, 10000);
    if (result.timedOut) throw new Error("Cancellation not confirmed; the task is still running. Inspect its log before native recovery.");
    if (result.task.status !== "canceled" && result.task.status !== "completed") {
      throw new Error(`Cancellation not confirmed: ${formatError(result.task.error || result.task.status)}`);
    }
    return result.task;
  }

  return {
    cancel, dispatch, find, logs, read, startSeed, wait,
    export: id => launch({ kind: "export", workItem: id }),
    sync: (id, commit) => launch({ kind: "sync", workItem: id, commit }),
  };
}
