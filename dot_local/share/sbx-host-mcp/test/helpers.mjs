import { spawn } from "node:child_process";
import { once } from "node:events";
import { watch } from "node:fs";
import { createInterface } from "node:readline";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { configuration, git, readJson, run } from "../lib/runtime.mjs";
import { createTaskManager } from "../lib/tasks.mjs";

export async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "sbx-host-test-"));
  const repos = join(root, "repos"), state = join(root, "state"), bin = join(root, "bin");
  const repo = join(repos, "example-repo"), remote = join(root, "origin.git");
  await mkdir(repo, { recursive: true });
  await mkdir(bin);
  await run("git", ["init", "-q", "--bare", "--initial-branch=master", remote]);
  await run("git", ["init", "-q", "--initial-branch=master", repo]);
  await git(repo, "config", "user.name", "Test User");
  await git(repo, "config", "user.email", "test@example.com");
  await git(repo, "config", "commit.gpgsign", "false");
  await writeFile(join(repo, "baseline.txt"), "baseline\n");
  await git(repo, "add", ".");
  await git(repo, "commit", "-qm", "Baseline");
  await git(repo, "remote", "add", "origin", remote);
  await git(repo, "push", "-qu", "origin", "master");
  await git(repo, "remote", "set-head", "origin", "master");
  await writeFile(join(bin, "corepack"), `#!/usr/bin/env node
import { mkdir, writeFile } from "node:fs/promises";
if (process.argv[2] !== "enable") {
  if (!process.env.ADO_NPM_TOKEN) process.exit(8);
  await mkdir(".yarn", {recursive:true});
  await writeFile(".yarn/install-state.gz", "restored");
}
`, { mode: 0o700 });
  await writeFile(join(bin, "copilot"), `#!/usr/bin/env node
import { spawn } from "node:child_process";
if (process.argv.at(-1).startsWith("WAIT_RUNNING")) {
  const child = spawn(process.execPath, ["-e", "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000)"], {stdio:"ignore"});
  console.log("agent-child=" + child.pid);
  setTimeout(() => process.exit(9), 30000);
} else console.log("agent completed task");
`, { mode: 0o700 });
  await writeFile(join(bin, "wslpath"), "#!/usr/bin/env node\nconsole.log(process.argv.at(-1));\n", { mode: 0o700 });
  const sbx = join(bin, "sbx");
  await writeFile(sbx, `#!/usr/bin/env node\nimport(${JSON.stringify(new URL("./fake-sbx.mjs", import.meta.url).href)}).catch(error => { console.error(error); process.exitCode = 1; });\n`, { mode: 0o700 });
  const env = {
    ...process.env, PATH: `${bin}:${process.env.PATH}`,
    SBX_WORK_SBX_BIN: sbx,
    SBX_HOST_REPOS_ROOT: repos, SBX_HOST_STATE_ROOT: state,
    FAKE_SBX_ROOT: join(root, "vms"), FAKE_SBX_LOG: join(root, "sbx.log"),
    SBX_WORK_ADO_ORGANIZATION: "example",
  };
  const config = configuration({ env, home: root });
  const paths = { root, repos, state, repo, remote, bin, env, config };
  t.after(async () => {
    const tasks = createTaskManager(config);
    for (const file of await readdir(config.tasksRoot).catch(() => [])) {
      if (!file.endsWith(".json")) continue;
      const task = await tasks.read(file.slice(0, -5));
      if (task.status === "running") {
        if (task.kind === "copilot") await tasks.cancel(task.taskId).catch(() => {});
        else await tasks.wait(task.taskId, 10000).catch(() => {});
      }
    }
    await rm(root, { recursive: true, force: true });
  });
  return paths;
}

export async function commit(repo, file, content = `${file}\n`) {
  await writeFile(join(repo, file), content);
  await git(repo, "add", file);
  await git(repo, "commit", "-qm", `Add ${file}`);
  return git(repo, "rev-parse", "HEAD");
}

export function startServer(t, paths) {
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: new URL("..", import.meta.url), env: paths.env, stdio: ["pipe", "pipe", "pipe"],
  });
  const lines = createInterface({ input: child.stdout });
  const pending = new Map();
  let id = 0, stderr = "";
  child.stderr.on("data", chunk => { stderr += chunk; });
  lines.on("line", line => {
    const message = JSON.parse(line);
    if (message.id !== undefined) { pending.get(message.id)?.resolve(message); pending.delete(message.id); }
  });
  child.on("close", () => {
    for (const request of pending.values()) request.reject(new Error(`MCP server exited: ${stderr}`));
  });
  t.after(() => { child.kill(); lines.close(); });
  const send = message => child.stdin.write(`${JSON.stringify(message)}\n`);
  const request = (method, params) => new Promise((resolve, reject) => {
    pending.set(++id, { resolve, reject });
    send({ jsonrpc: "2.0", id, method, params });
  });
  return {
    child, request,
    async initialize() {
      await request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
      send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
    },
    async call(name, args) {
      const response = await request("tools/call", { name, arguments: args });
      if (response.result.isError) throw new Error(response.result.content[0].text);
      return JSON.parse(response.result.content[0].text);
    },
  };
}

export const transferState = paths => readJson(join(paths.state, "123.json"));

export async function waitForLog(paths, id, pattern, timeout = 5000) {
  const file = join(paths.config.tasksRoot, `${id}.log`);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error("task did not reach expected execution state")), timeout);
  const events = watch(paths.config.tasksRoot, { signal: controller.signal });
  try {
    let text = await readFile(file, "utf8");
    while (!pattern.test(text)) {
      await once(events, "change", { signal: controller.signal });
      text = await readFile(file, "utf8");
    }
    return text.match(pattern);
  } finally { clearTimeout(timer); events.close(); }
}
