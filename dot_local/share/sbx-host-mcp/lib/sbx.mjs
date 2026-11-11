import { spawn } from "node:child_process";
import { access, constants } from "node:fs/promises";
import { join } from "node:path";
import { run } from "./runtime.mjs";

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
  const args = values => [values[0], "--no-input", ...values.slice(1)];
  const hostPath = path => windows ? run("wslpath", ["-w", path], { env }) : Promise.resolve(path);

  function environment(values = {}) {
    return {
      ...env, ...values,
      ...(windows && Object.keys(values).length ? {
        WSLENV: [env.WSLENV, ...Object.keys(values)].filter(Boolean).join(":"),
      } : {}),
    };
  }
  const call = (values, options = {}) => run(executable, args(values), {
    ...options, env: environment(options.variables),
  });
  return {
    call,
    exec: (sandbox, values, options) => call(["exec", sandbox, "--", ...values], options),
    spawn: (values, options) => spawn(executable, args(values), { env, ...options }),
    copyTo: async (sandbox, source, target) => call(["cp", await hostPath(source), `${sandbox}:${target}`]),
    copyFrom: async (sandbox, source, target) => call(["cp", `${sandbox}:${source}`, await hostPath(target)]),
  };
}
