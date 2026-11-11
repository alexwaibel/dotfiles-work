import { run } from "./runtime.mjs";

/** Acquire a package-read token through Windows AzureAuth without persisting it. */
export async function packageReadToken(config, organization, sandbox) {
  if (!organization || !/^[A-Za-z0-9._-]+$/.test(organization)) {
    throw new Error("cannot derive a valid Azure DevOps organization");
  }
  const token = await run(config.env.SBX_WORK_POWERSHELL_BIN || "powershell.exe", [
    "-NoProfile", "-Command",
    `azureauth ado pat --organization '${organization}' --display-name 'DockerSandbox-${sandbox}' --scope vso.packaging --output token --prompt-hint 'DockerSandbox-${sandbox}' --timeout 30`,
  ], { env: config.env });
  if (!token || /[\r\n]/.test(token)) throw new Error("Windows Azure authentication returned an invalid token");
  return token;
}
