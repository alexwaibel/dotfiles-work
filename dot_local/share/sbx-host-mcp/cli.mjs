#!/usr/bin/env node

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const helper = join(homedir(), ".local", "share", "sbx-host-mcp", "sbx-work.sh");
const child = spawn("/usr/bin/bash", [helper, ...process.argv.slice(2)], {
  stdio: "inherit",
  env: process.env,
});

child.on("error", error => {
  console.error(error.message);
  process.exitCode = 1;
});

child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exitCode = code ?? 1;
});
