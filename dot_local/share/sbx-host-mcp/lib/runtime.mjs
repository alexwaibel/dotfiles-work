import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

export function configuration(options = {}) {
  const env = options.env || process.env;
  const home = options.home || homedir();
  const stateRoot = options.stateRoot || env.SBX_HOST_STATE_ROOT ||
    env.SBX_WORK_STATE_ROOT || join(env.XDG_STATE_HOME || join(home, ".local", "state"), "sbx-work");
  return {
    env, home,
    reposRoot: resolve(options.reposRoot || env.SBX_HOST_REPOS_ROOT || env.SBX_WORK_REPOS_ROOT || join(home, "repos")),
    stateRoot: resolve(stateRoot),
    tasksRoot: resolve(options.tasksRoot || env.SBX_WORK_TASKS_ROOT || join(stateRoot, "tasks")),
  };
}

export function workItem(value) {
  if (!/^[1-9][0-9]*$/.test(String(value)) || !Number.isSafeInteger(Number(value))) {
    throw new Error("work item must be a positive safe integer");
  }
  return Number(value);
}

export function taskId(value) {
  if (!/^task-[a-f0-9-]{36}$/.test(value)) throw new Error("invalid task ID");
  return value;
}

export function commitSha(value) {
  if (!/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(value)) throw new Error("a full commit SHA is required");
  return value;
}

export async function canonicalRepo(config, name) {
  if (!/^[A-Za-z0-9._-]+$/.test(name) || name === "." || name === "..") {
    throw new Error("invalid repository name");
  }
  const path = resolve(config.reposRoot, name);
  if (!(await stat(join(path, ".git"))).isDirectory() ||
      await realpath(path) !== path || await realpath(join(path, ".git")) !== join(path, ".git")) {
    throw new Error("repository must be a canonical clone under the repository root");
  }
  return path;
}

export const readJson = async path => JSON.parse(await readFile(path, "utf8"));

export async function writeJson(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, JSON.stringify(value), { mode: 0o600 });
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true });
  }
}

export function formatError(error) {
  const message = error instanceof Error ? error.message : String(error);
  return message.length > 32768 ? `[output truncated]\n${message.slice(-32768)}` : message;
}

export function run(file, args, { input, output, env = process.env, cwd } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, {
      env, cwd,
      stdio: [input === undefined ? "ignore" : "pipe", output ?? "pipe", output ?? "pipe"],
    });
    let stdout = "", stderr = "";
    child.stdout?.on("data", chunk => { stdout = (stdout + chunk).slice(-8 * 1024 * 1024); });
    child.stderr?.on("data", chunk => { stderr = (stderr + chunk).slice(-32768); });
    child.once("error", reject);
    child.once("close", (code, signal) => {
      if (code === 0) resolve(stdout.trim());
      else reject(Object.assign(new Error(stderr.trim() || `${file} exited (${signal || code})`), { exitCode: code || 1 }));
    });
    if (input !== undefined) {
      child.stdin.on("error", error => { if (error.code !== "EPIPE") reject(error); });
      child.stdin.end(input);
    }
  });
}

export const git = (repo, ...args) => run("git", ["-C", repo, ...args]);

export async function processIdentity(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return undefined;
  try {
    const [stat, boot] = await Promise.all([
      readFile(`/proc/${pid}/stat`, "utf8"),
      readFile("/proc/sys/kernel/random/boot_id", "utf8"),
    ]);
    const fields = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/);
    return fields[0] === "Z" ? undefined : `${boot.trim()}:${fields[19]}`;
  } catch (error) {
    if (error.code === "ENOENT") return undefined;
    throw error;
  }
}
