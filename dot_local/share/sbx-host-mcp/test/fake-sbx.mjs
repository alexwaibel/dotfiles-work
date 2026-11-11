#!/usr/bin/env node
import { spawn } from "node:child_process";
import { appendFile, copyFile, mkdir, readdir, rm } from "node:fs/promises";
import { join } from "node:path";

const [command, ...args] = process.argv.slice(2).filter(value => value !== "--no-input");
const root = process.env.FAKE_SBX_ROOT;
await appendFile(process.env.FAKE_SBX_LOG, `${JSON.stringify({ command, args, wslenv: process.env.WSLENV })}\n`);
if (process.env.FAKE_SBX_FAIL === command) { console.error("fixture failure"); process.exit(7); }
switch (command) {
  case "create": {
    const name = args[args.indexOf("--name") + 1];
    if (args.at(-1) !== "copilot" || args.includes("--clone")) throw new Error("expected mountless Copilot");
    await mkdir(join(root, name, "workspace"), { recursive: true });
    await mkdir(join(root, name, "home"), { recursive: true });
    break;
  }
  case "run": case "policy": case "stop": break;
  case "rm": {
    const name = args.at(-1);
    await rm(join(root, name), { recursive: true });
    break;
  }
  case "ls": console.log((await readdir(root)).join("\n")); break;
  case "cp": {
    const localPath = value => value.replace(/^[a-z0-9][a-z0-9.-]*:(\/)/, "$1");
    await copyFile(localPath(args[0]), localPath(args[1]));
    break;
  }
  case "exec": {
    let index = 0, cwd;
    const env = { ...process.env };
    while (args[index]?.startsWith("-")) {
      const option = args[index++];
      if (option === "-w") cwd = args[index++];
      else if (option === "-e") env[args[index++]] = process.env[args[index - 1]];
      else if (option !== "-i") throw new Error(`unexpected exec option ${option}`);
    }
    const name = args[index++];
    if (args[index++] !== "--") throw new Error("missing command separator");
    cwd ||= join(root, name, "workspace");
    env.HOME = join(root, name, "home");
    const values = args.slice(index);
    const child = spawn(values[0], values.slice(1), { cwd, env, stdio: "inherit" });
    child.on("error", error => { console.error(error.message); process.exitCode = 127; });
    child.on("close", (code, signal) => { process.exitCode = code ?? (signal ? 137 : 1); });
    break;
  }
  default: throw new Error(`unexpected sbx command ${command}`);
}
