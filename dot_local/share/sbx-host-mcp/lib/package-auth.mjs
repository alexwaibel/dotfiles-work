import { git, run } from "./runtime.mjs";

export async function packageReadToken(config, repo, id) {
  const remote = await git(repo, "remote", "get-url", "origin");
  const organization = config.env.SBX_WORK_ADO_ORGANIZATION ||
    /^https:\/\/([^.]+)\.visualstudio\.com\//.exec(remote)?.[1] ||
    /^https:\/\/dev\.azure\.com\/([^/]+)\//.exec(remote)?.[1];
  if (!organization || !/^[A-Za-z0-9._-]+$/.test(organization)) {
    throw new Error("cannot derive a valid Azure DevOps organization");
  }
  const token = await run(config.env.SBX_WORK_POWERSHELL_BIN || "powershell.exe", [
    "-NoProfile", "-Command",
    `azureauth ado pat --organization '${organization}' --display-name 'DockerSandbox-wi-${id}' --scope vso.packaging --output token --prompt-hint 'DockerSandbox-wi-${id}' --timeout 30`,
  ], { env: config.env });
  if (!token || /[\r\n]/.test(token)) throw new Error("Windows Azure authentication returned an invalid token");
  return token;
}
