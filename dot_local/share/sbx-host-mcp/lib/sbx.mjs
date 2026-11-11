import { spawn } from "node:child_process";
import { access, constants } from "node:fs/promises";
import { join } from "node:path";
import { run } from "./runtime.mjs";

/** Locate sbx and adapt host paths and environment forwarding for Windows interop. */
export async function createSbx({ env = process.env } = {}) {
  const candidates = env.SBX_WORK_SBX_BIN ? [env.SBX_WORK_SBX_BIN] : [
    ...(env.PATH || "").split(":").flatMap(path => [join(path, "sbx"), join(path, "sbx.exe")]),
    `/mnt/c/Users/${env.USER}/AppData/Local/DockerSandboxes/bin/sbx.exe`,
  ];
  let executable;
  for (const candidate of candidates) {
    try { await access(candidate, constants.X_OK); executable = candidate; break; }
    catch (error) { if (!["ENOENT", "EACCES", "ENOTDIR"].includes(error.code)) throw error; }
  }
  if (!executable) throw new Error("sbx not found; set SBX_WORK_SBX_BIN");
  const windows = executable.endsWith(".exe");
  /** Disable prompts so native operations fail rather than wait for terminal input. */
  const args = values => [values[0], "--no-input", ...values.slice(1)];
  /** Convert host paths only when invoking the Windows executable. */
  const hostPath = path => windows ? run("wslpath", ["-w", path], { env }) : Promise.resolve(path);

  /** Forward explicit variables across the WSL boundary through WSLENV. */
  function environment(values = {}) {
    return {
      ...env, ...values,
      ...(windows && Object.keys(values).length ? {
        WSLENV: [env.WSLENV, ...Object.keys(values)].filter(Boolean).join(":"),
      } : {}),
    };
  }
  /** Collect a native sbx invocation's output using the adapted environment. */
  const call = (values, options = {}) => run(executable, args(values), {
    ...options, env: environment(options.variables),
  });
  return {
    call,
    /** Execute an argument array inside a named VM. */
    exec: (sandbox, values, options) => call(["exec", sandbox, "--", ...values], options),
    /** Return a raw child process when the caller needs streaming control. */
    spawn: (values, options) => spawn(executable, args(values), { env, ...options }),
    /** Upload a host file after translating its path for the native executable. */
    copyTo: async (sandbox, source, target) => call(["cp", await hostPath(source), `${sandbox}:${target}`]),
    /** Download a VM file to a translated host destination. */
    copyFrom: async (sandbox, source, target) => call(["cp", `${sandbox}:${source}`, await hostPath(target)]),
  };
}
