import { randomUUID } from "node:crypto";
import { lstat, mkdir, open, realpath, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { createSbx } from "./sbx.mjs";
import { packageReadToken } from "./package-auth.mjs";

/** Build the host bridge for VM execution, bounded transfers, and private restore. */
export async function createBridge({ env = process.env } = {}) {
  const sbx = await createSbx({ env });
  const transferRoot = resolve(env.SBX_HOST_TRANSFER_ROOT || join(homedir(), "repos", ".sbx-transfer"));
  const profileRoot = resolve(env.SBX_HOST_PROFILE_ROOT || join(homedir(), ".local", "share", "sbx-copilot-profile"));
  /** Validate and return a non-reserved sandbox name. */
  const name = value => {
    if (typeof value !== "string" || !/^[a-z0-9][a-z0-9.-]{1,62}$/.test(value) || value === "default") throw new Error("invalid sandbox name");
    return value;
  };
  /** Reject relative or NUL-containing paths before invoking VM commands. */
  const vmPath = value => {
    if (typeof value !== "string" || !isAbsolute(value) || value.includes("\0")) throw new Error("VM path must be absolute");
    return value;
  };
  /** Run a foreground VM script and return its output and native exit code. */
  async function execute(sandbox, cwd, script, variables = {}) {
    name(sandbox); vmPath(cwd);
    if (typeof script !== "string" || !script.length || script.length > 64000) throw new Error("invalid script");
    try {
      const output = await sbx.call(["exec", "-i", "-w", cwd,
        ...Object.keys(variables).flatMap(key => ["-e", key]),
        sandbox, "--", "bash", "-s",
      ], { input: `exec 2>&1\nexport PATH="$HOME/.local/bin:$PATH"\n${script}`, variables });
      return { output, exitCode: 0 };
    } catch (error) {
      if (!Number.isInteger(error.code)) throw error;
      return { output: error.stdout.trim(), stderr: error.stderr.trim(), exitCode: error.code };
    }
  }
  /** Transfer regular files through host staging; downloads never overwrite files. */
  async function copy({ sandbox, direction, vmPath: remote, file }) {
    name(sandbox); vmPath(remote);
    if (!["to", "from"].includes(direction)) throw new Error("invalid direction");
    await mkdir(transferRoot, { recursive: true, mode: 0o700 });
    if (await realpath(transferRoot) !== transferRoot) throw new Error("transfer directory must not use symbolic links");
    if (direction === "to") {
      if (typeof file !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$/.test(file)) throw new Error("use a staged filename, not a host path");
      const source = join(transferRoot, file);
      if (!(await lstat(source)).isFile() || await realpath(source) !== source) throw new Error("staged input must be a regular file, not a symbolic link");
      await sbx.copyTo(sandbox, source, remote);
      return { file };
    }
    await sbx.exec(sandbox, ["test", "-f", remote]);
    await sbx.exec(sandbox, ["test", "!", "-L", remote]);
    const target = join(transferRoot, `${randomUUID()}.download`);
    const handle = await open(target, "wx", 0o600);
    await handle.close();
    try {
      await sbx.copyFrom(sandbox, remote, target);
      if (!(await lstat(target)).isFile() || await realpath(target) !== target) throw new Error("download must be a regular file");
      return { file: target.slice(transferRoot.length + 1), path: target };
    } catch (error) {
      await rm(target, { force: true });
      throw error;
    }
  }
  /** Run a private package install with process-only credentials and scripts disabled. */
  async function restore({ sandbox, cwd, organization }) {
    name(sandbox); vmPath(cwd);
    const metadata = JSON.parse(await sbx.exec(sandbox, ["node", "-e",
      'const fs=require("fs"),p=process.argv[1]; const pkg=JSON.parse(fs.readFileSync(p+"/package.json")); console.log(JSON.stringify({manager:pkg.packageManager,lock:fs.existsSync(p+"/package-lock.json")}))', cwd]));
    let command;
    if (/^yarn@(?:[2-9]|[1-9]\d+)\./.test(metadata.manager)) command = "yarn install --immutable";
    else if (/^yarn@1\./.test(metadata.manager)) command = "yarn install --frozen-lockfile";
    else if (/^pnpm@/.test(metadata.manager)) command = "pnpm install --frozen-lockfile --ignore-scripts";
    else if (/^npm@/.test(metadata.manager) && metadata.lock) command = "npm ci --ignore-scripts";
    else throw new Error("declare a supported packageManager (and package-lock.json for npm) before private restore");
    const token = await packageReadToken({ env }, organization, sandbox);
    await sbx.call(["policy", "allow", "network", "--sandbox", sandbox, "**.vsassets.io"]);
    return execute(sandbox, cwd, command, {
      ADO_NPM_TOKEN: token, YARN_ENABLE_SCRIPTS: "false",
      npm_config_ignore_scripts: "true", PNPM_CONFIG_IGNORE_SCRIPTS: "true",
    });
  }
  return {
    /** List native sandboxes without requiring workflow registrations. */
    list: async () => ({ output: await sbx.call(["ls"]) }),
    /** Create a mountless VM with the portable profile, not host MCPs or shared skills. */
    async create({ sandbox }) {
      name(sandbox);
      await sbx.call(["create", "--name", sandbox, "--static-mcp", "none", "--skills", "off",
        "--kit", await sbx.hostPath(profileRoot), "copilot"]);
      await sbx.call(["run", "-d", "--name", sandbox]);
      return { sandbox };
    },
    /** Run a supplied shell script inside the VM, not on the host. */
    exec: ({ sandbox, cwd, script }) => execute(sandbox, cwd, script),
    copy, restore,
    /** Stop the VM and its commands while retaining its files. */
    stop: async ({ sandbox }) => ({ output: await sbx.call(["stop", name(sandbox)]) }),
    /** Delete the VM and its contents without an interactive confirmation. */
    remove: async ({ sandbox }) => ({ output: await sbx.call(["rm", "--force", name(sandbox)]) }),
  };
}
