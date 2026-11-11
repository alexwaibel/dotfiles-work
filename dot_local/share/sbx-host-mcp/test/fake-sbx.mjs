#!/usr/bin/env node
import { spawn } from "node:child_process";
import { appendFile, copyFile, mkdir, readdir, rm } from "node:fs/promises";
import { join, dirname } from "node:path";
import { setTimeout } from "node:timers/promises";

const [command, ...args] = process.argv.slice(2).filter(value => value !== "--no-input");
const root = process.env.FAKE_SBX_ROOT;
await mkdir(root, { recursive: true });
await appendFile(process.env.FAKE_SBX_LOG, `${JSON.stringify({
  command, args, tokenPresent: !!process.env.ADO_NPM_TOKEN, wslenv: process.env.WSLENV,
})}\n`);
if (process.env.FAKE_SBX_FAIL === command) {
  console.error("fixture seed failed");
  process.exit(7);
}
switch (command) {
  case "create": {
    if (process.env.FAKE_SBX_SLOW_CREATE) await setTimeout(1000);
    const name = args[args.indexOf("--name") + 1];
    if (args.includes("--clone") || args.at(-1) !== "copilot") throw new Error("expected a mountless sandbox");
    await mkdir(join(root, name, "workspace"), { recursive: true });
    const home = join(root, name, "home");
    await mkdir(join(home, ".local/bin"), { recursive: true });
    for (const tool of ["copilot", "corepack"]) {
      await copyFile(join(dirname(process.env.SBX_WORK_SBX_BIN), tool), join(home, ".local/bin", tool));
    }
    break;
  }
  case "run": case "policy": break;
  case "rm":
    await rm(join(root, args.at(-1)), { recursive: true, force: true });
    break;
  case "ls":
    if (process.env.FAKE_SBX_WARNING) console.error("harmless native warning");
    console.log((await readdir(root)).join("\n"));
    break;
  case "cp": {
    const localPath = value => value.replace(/^wi-[0-9]+-vm:/, "");
    const source = localPath(args[0]), target = localPath(args[1]);
    await mkdir(dirname(target), { recursive: true });
    await copyFile(source, target);
    if (target.endsWith(".bundle") && process.env.FAKE_SBX_CORRUPT) {
      await copyFile(new URL(import.meta.url), target);
    }
    if (target.endsWith(".bundle") && process.env.FAKE_SBX_REPLACEMENT) {
      await copyFile(process.env.FAKE_SBX_REPLACEMENT, target);
    }
    break;
  }
  case "exec": {
    let index = 0, cwd;
    const env = { ...process.env };
    while (args[index]?.startsWith("-")) {
      const option = args[index++];
      if (option === "-w") cwd = args[index++];
      else if (option === "-e") {
        const [key, ...value] = args[index++].split("=");
        env[key] = value.length ? value.join("=") : process.env[key];
      } else if (option !== "-i") throw new Error(`unexpected exec option ${option}`);
    }
    const name = args[index++];
    if (args[index++] !== "--") throw new Error("missing command separator");
    cwd ||= join(root, name, "workspace");
    env.HOME = join(root, name, "home");
    await mkdir(env.HOME, { recursive: true });
    const values = args.slice(index);
    if (process.env.FAKE_SBX_FAIL === "bootstrap" && values.some(value => value.endsWith("-bootstrap.sh"))) {
      console.error("fixture seed failed"); process.exit(7);
    }
    const child = spawn(values[0], values.slice(1), { cwd, env, stdio: "inherit" });
    child.on("error", error => { console.error(error.message); process.exitCode = 127; });
    child.on("close", (code, signal) => { process.exitCode = code ?? (signal ? 137 : 1); });
    break;
  }
  default: throw new Error(`unexpected sbx command ${command}`);
}
