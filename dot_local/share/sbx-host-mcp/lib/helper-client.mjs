import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export function createHelperClient({
  helper,
  home,
  maxBuffer = 8 * 1024 * 1024,
  maxResult = 32 * 1024,
  timeout = 15 * 60 * 1000,
  env = process.env,
}) {
  function truncate(text) {
    if (text.length <= maxResult) return text;
    return `[output truncated to final ${maxResult} bytes]\n${text.slice(-maxResult)}`;
  }

  function formatError(error) {
    if (error && typeof error === "object") {
      const stderr = typeof error.stderr === "string" ? error.stderr.trim() : "";
      const stdout = typeof error.stdout === "string" ? error.stdout.trim() : "";
      const message = error instanceof Error ? error.message : String(error);
      return truncate([message, stderr, stdout].filter(Boolean).join("\n"));
    }
    return String(error);
  }

  async function run(args) {
    const { stdout, stderr } = await execFileAsync(
      "/usr/bin/bash",
      [helper, ...args],
      {
        cwd: home,
        env,
        encoding: "utf8",
        maxBuffer,
        timeout,
        windowsHide: true,
      },
    );
    return truncate(
      [stdout.trim(), stderr.trim()].filter(Boolean).join("\n"),
    );
  }

  return { formatError, run };
}
