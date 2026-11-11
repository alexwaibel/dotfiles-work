import { spawnSync } from "node:child_process";
import { once } from "node:events";
import { closeSync } from "node:fs";
import { join } from "node:path";
import { configuration, formatError, processIdentity, writeJson } from "./lib/runtime.mjs";
import { createSandbox } from "./lib/sandbox.mjs";
import { runAgent } from "./lib/agent.mjs";

const lock = spawnSync("flock", ["--nonblock", "--conflict-exit-code", "73", "4"], {
  stdio: ["ignore", "ignore", "pipe", "ignore", 4],
});
if (lock.error) throw lock.error;
if (lock.status !== 0) {
  console.error(lock.stderr.toString());
  process.exit(lock.status || 1);
}
const cancellation = new AbortController();
process.on("SIGTERM", () => cancellation.abort());
process.on("SIGINT", () => cancellation.abort());
const [request] = await once(process, "message");
const config = configuration();
const sandbox = createSandbox(config);
let task, path;
try {
  if (!["seed", "copilot", "export", "sync"].includes(request.kind)) throw new Error("unsupported operation");
  if (request.kind === "export" || request.kind === "sync") {
    const result = await sandbox[request.kind](request.workItem, request.commit);
    process.send({ result });
  } else {
    const { prompt, ...metadata } = request;
    let checkout;
    if (request.kind === "copilot") {
      checkout = await sandbox.inspect(request.workItem);
      if (checkout.sandboxStatus !== "present") throw new Error(`Sandbox is not ready: ${checkout.sandboxStatus}`);
    }
    task = {
      ...metadata,
      sandbox: checkout?.sandbox || `wi-${request.workItem}-vm`,
      ...(checkout ? { repoDir: checkout.repoDir } : {}),
      createdAt: new Date().toISOString(), startedAt: new Date().toISOString(),
      status: "running", runnerPid: process.pid,
      runnerIdentity: await processIdentity(process.pid),
    };
    path = join(config.tasksRoot, `${task.taskId}.json`);
    await writeJson(path, task);
    process.send({ result: task });
    process.disconnect();
    const result = request.kind === "seed"
      ? await sandbox.seed(request.workItem, request.seed)
      : await runAgent(config, task, prompt, cancellation.signal);
    task.status = result.canceled ? "canceled" : "completed";
    task.exitCode = result.canceled ? 130 : 0;
  }
} catch (error) {
  console.error(formatError(error));
  if (task) {
    task.status = "failed";
    task.exitCode = error.exitCode || 1;
    task.error = formatError(error);
  } else if (process.connected) process.send({ error: formatError(error) });
  process.exitCode = 1;
} finally {
  closeSync(4);
  if (task) {
    task.completedAt = new Date().toISOString();
    await writeJson(path, task);
  }
  if (process.connected) process.disconnect();
}
