import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { mkdtemp, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createBridge } from "../lib/bridge.mjs";
import { run } from "../lib/runtime.mjs";

export async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "sbx-bridge-test-"));
  const bin = join(root, "bin"), vms = join(root, "vms"), transfer = join(root, "transfer");
  await Promise.all([bin, vms, transfer].map(path => mkdir(path)));
  const sbx = join(bin, "sbx");
  await writeFile(sbx, `#!/usr/bin/env node\nimport(${JSON.stringify(new URL("./fake-sbx.mjs", import.meta.url).href)}).catch(error => { console.error(error); process.exitCode = 1; });\n`, { mode: 0o700 });
  const auth = join(bin, "powershell");
  await writeFile(auth, '#!/usr/bin/env node\nconsole.log("fixture-package-token");\n', { mode: 0o700 });
  const installer = `#!/usr/bin/env node
import {mkdir} from "node:fs/promises";
console.log(JSON.stringify({args:process.argv.slice(2),tokenPresent:!!process.env.ADO_NPM_TOKEN,scripts:process.env.npm_config_ignore_scripts,yarnScripts:process.env.YARN_ENABLE_SCRIPTS}));
await mkdir("node_modules",{recursive:true});
`;
  for (const tool of ["yarn", "npm", "pnpm"]) await writeFile(join(bin, tool), installer, { mode: 0o700 });
  const env = {
    ...process.env, PATH: `${bin}:${process.env.PATH}`,
    SBX_WORK_SBX_BIN: sbx, SBX_WORK_POWERSHELL_BIN: auth,
    SBX_HOST_TRANSFER_ROOT: transfer, FAKE_SBX_ROOT: vms,
    FAKE_SBX_LOG: join(root, "sbx.log"),
  };
  const bridge = await createBridge({ env });
  t.after(async () => {
    for (const sandbox of await readdir(vms)) await bridge.stop({ sandbox }).catch(() => {});
    await rm(root, { recursive: true, force: true });
  });
  return { root, bin, vms, transfer, env, bridge, cwd: name => join(vms, name, "workspace") };
}

export const git = (repo, ...args) => run("git", ["-C", repo, ...args]);
export const log = paths => readFile(join(paths.root, "sbx.log"), "utf8");

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
      if (response.error) throw new Error(response.error.message);
      if (response.result.isError) throw new Error(response.result.content[0].text);
      return JSON.parse(response.result.content[0].text);
    },
  };
}
