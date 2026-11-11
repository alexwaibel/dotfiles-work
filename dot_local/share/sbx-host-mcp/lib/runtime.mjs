import { execFile } from "node:child_process";
import { finished } from "node:stream/promises";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/** Return trimmed stdout; reject execution failures or output beyond the 8 MiB limit. */
export async function run(file, args, { input, env = process.env, cwd } = {}) {
  const pending = execFileAsync(file, args, { env, cwd, maxBuffer: 8 * 1024 * 1024 });
  const stdin = finished(pending.child.stdin).catch(error => {
    if (error.code !== "EPIPE") throw error;
  });
  pending.child.stdin.end(input);
  const [{ stdout }] = await Promise.all([pending, stdin]);
  return stdout.trim();
}
