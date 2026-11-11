import { randomUUID } from "node:crypto";
import { mkdir, mkdtemp, rm, rmdir } from "node:fs/promises";
import { join, posix } from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalRepo, commitSha, git, readJson, workItem, writeJson } from "./runtime.mjs";
import { createSbx } from "./sbx.mjs";
import { packageReadToken } from "./package-auth.mjs";

const exported = state => ["hostWorktree", "importedCommit", "exportedCommit", "syncedCommit"].some(key => key in state);
const fields = ["workItem", "slug", "repo", "sandbox", "branch", "baseBranch", "baseSha", "repoDir", "importedCommit", "importedRef", "syncedCommit"];
const bootstrap = fileURLToPath(new URL("../vm/bootstrap.sh", import.meta.url));

export function createSandbox(config) {
  const statePath = id => join(config.stateRoot, `${workItem(id)}.json`);
  const state = id => readJson(statePath(id));
  const save = (id, value) => writeJson(statePath(id), value);

  async function exists(sbx, name) {
    return (await sbx.call(["ls", "-q"])).split(/\r?\n/).includes(name);
  }

  async function inspect(id) {
    const value = await state(id);
    const present = await exists(await createSbx(config), value.sandbox);
    return {
      ...Object.fromEntries(fields.filter(key => value[key] !== undefined).map(key => [key, value[key]])),
      sandboxStatus: present ? "present" : exported(value) ? "missing-exported" : "missing-unexported",
    };
  }

  async function cleanCheckout(sbx, value) {
    if (await sbx.exec(value.sandbox, ["git", "-C", value.repoDir, "status", "--porcelain"])) {
      throw new Error("sandbox repository has uncommitted changes");
    }
    if (await sbx.exec(value.sandbox, ["git", "-C", value.repoDir, "branch", "--show-current"]) !== value.branch) {
      throw new Error("sandbox repository is not on the expected branch");
    }
  }

  async function transferFile(id, sandbox, callback) {
    await mkdir(config.stateRoot, { recursive: true, mode: 0o700 });
    const directory = await mkdtemp(join(config.stateRoot, "transfer-"));
    const local = join(directory, "commits.bundle");
    const remote = `/tmp/sbx-work-${id}-${randomUUID()}.bundle`;
    const sbx = await createSbx(config);
    try {
      return await callback({ sbx, local, remote });
    } finally {
      await sbx.exec(sandbox, ["rm", "-f", "--", remote]).catch(() => {});
      await rm(local, { force: true });
      await rmdir(directory);
    }
  }

  async function sendCommit(id, value, commit, initialize) {
    const repo = await canonicalRepo(config, value.repo);
    if (await git(repo, "rev-parse", "--verify", `${commitSha(commit)}^{commit}`) !== commit) {
      throw new Error("sync source is not an available commit");
    }
    const ref = `refs/sbx-work/transfers/${id}/${randomUUID()}`;
    await git(repo, "update-ref", ref, commit, "");
    try {
      await transferFile(id, value.sandbox, async ({ sbx, local, remote }) => {
        await git(repo, "bundle", "create", local, ref);
        await git(repo, "bundle", "verify", local);
        if (await git(repo, "bundle", "list-heads", local, ref) !== `${commit} ${ref}`) {
          throw new Error("bundle does not match the requested commit");
        }
        await sbx.copyTo(value.sandbox, local, remote);
        const vmGit = (...args) => sbx.exec(value.sandbox, ["git", "-C", value.repoDir, ...args]);
        if (initialize) await sbx.exec(value.sandbox, ["git", "init", "-q", value.repoDir]);
        await vmGit("bundle", "verify", remote);
        if (await vmGit("bundle", "list-heads", remote, ref) !== `${commit} ${ref}`) {
          throw new Error("copied bundle does not match the requested commit");
        }
        await vmGit("fetch", "--no-tags", remote, ref);
        if (initialize) await initialize(sbx);
        else await vmGit("reset", "--hard", commit);
        if (await vmGit("rev-parse", "HEAD") !== commit) throw new Error("VM HEAD does not match the requested commit");
      });
    } finally {
      await git(repo, "update-ref", "-d", ref, commit);
    }
  }

  async function seed(id, { slug, repo: name, reuseExistingBranch = false }) {
    id = workItem(id);
    if (!/^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?$/.test(slug)) throw new Error("invalid slug");
    const repo = await canonicalRepo(config, name);
    const sbx = await createSbx(config);
    const sandbox = `wi-${id}-vm`;
    const branch = `users/alwaibel/agent/${id}-${slug}`;
    let previous;
    try { previous = await state(id); } catch (error) { if (error.code !== "ENOENT") throw error; }
    if (await exists(sbx, sandbox)) throw new Error(`sandbox already exists: ${sandbox}`);
    if (previous) {
      if (previous.sandbox !== sandbox || (reuseExistingBranch &&
          (previous.repo !== name || previous.branch !== branch))) {
        throw new Error("existing metadata does not match the requested sandbox and branch");
      }
      if (!reuseExistingBranch && exported(previous)) throw new Error("stale metadata has exported host work; review it before replacement");
    }
    await git(repo, "fetch", "origin");
    let baseBranch;
    try { baseBranch = (await git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")).replace(/^origin\//, ""); }
    catch {
      for (const candidate of ["main", "master"]) {
        try { await git(repo, "show-ref", "--verify", "--quiet", `refs/remotes/origin/${candidate}`); baseBranch = candidate; break; }
        catch (error) { if (error.exitCode !== 1) throw error; }
      }
    }
    if (!baseBranch) throw new Error("cannot discover the default branch");
    if (!reuseExistingBranch) {
      for (const ref of [`refs/heads/${branch}`, `refs/remotes/origin/${branch}`]) {
        try { await git(repo, "show-ref", "--verify", "--quiet", ref); }
        catch (error) { if (error.exitCode === 1) continue; throw error; }
        throw new Error(`branch already exists: ${branch}`);
      }
    }
    const baseSha = await git(repo, "rev-parse", "--verify", `refs/remotes/origin/${reuseExistingBranch ? branch : baseBranch}^{commit}`);
    const gitName = await git(repo, "config", "user.name");
    const gitEmail = await git(repo, "config", "user.email");
    if (!gitName || !gitEmail) throw new Error("canonical repository must resolve a Git identity");
    const file = async name => {
      try { return await git(repo, "show", `${baseSha}:${name}`); }
      catch (error) { if (error.exitCode === 128) return ""; throw error; }
    };
    const [packageJson, npmConfig, yarnConfig] = await Promise.all([file("package.json"), file(".npmrc"), file(".yarnrc.yml")]);
    let install;
    if (/pkgs\.(dev\.azure\.com|visualstudio\.com)/.test(npmConfig + yarnConfig)) {
      const manager = JSON.parse(packageJson || "{}").packageManager || "";
      if (/^yarn@\d+/.test(manager)) install = ["yarn", "install", Number(manager.match(/\d+/)[0]) >= 2 ? "--immutable" : "--frozen-lockfile"];
      else if (/^pnpm@/.test(manager)) install = ["pnpm", "install", "--frozen-lockfile", "--ignore-scripts"];
      else if (/^npm@/.test(manager) && await file("package-lock.json")) install = ["npm", "ci", "--ignore-scripts"];
      else throw new Error("Azure Artifacts requires a supported packageManager");
    }
    let created = false;
    try {
      await sbx.call(["create", "--name", sandbox, "--static-mcp", "none", "--skills", "off", "copilot"]);
      created = true;
      await sbx.call(["run", "-d", "--name", sandbox]);
      const workspace = await sbx.exec(sandbox, ["pwd"]);
      if (!posix.isAbsolute(workspace)) throw new Error("sandbox returned an invalid workspace path");
      const value = { workItem: id, slug, repo: name, sandbox, branch, baseBranch, baseSha, repoDir: posix.join(workspace, name) };
      await sendCommit(id, value, baseSha, async transport => {
        const script = `/tmp/sbx-work-${id}-bootstrap.sh`;
        try {
          await transport.copyTo(sandbox, bootstrap, script);
          await transport.exec(sandbox, ["bash", script, value.repoDir, branch, baseSha, gitName, gitEmail]);
        } finally { await transport.exec(sandbox, ["rm", "-f", "--", script]).catch(() => {}); }
      });
      if (install) {
        await sbx.call(["policy", "allow", "network", "--sandbox", sandbox, "**.vsassets.io"]);
        const token = await packageReadToken(config, repo, id);
        await sbx.call(["exec", "-w", value.repoDir,
          "-e", "ADO_NPM_TOKEN", "-e", "YARN_ENABLE_SCRIPTS=false",
          "-e", "npm_config_ignore_scripts=true", "-e", "PNPM_CONFIG_IGNORE_SCRIPTS=true",
          sandbox, "--", "bash", "-lc", 'export PATH="$HOME/.local/bin:$PATH"; exec "$@"', "bash", ...install,
        ], { variables: { ADO_NPM_TOKEN: token }, output: 2 });
        const paths = { yarn: ["node_modules/.yarn-state.yml", ".pnp.cjs", ".yarn/install-state.gz"], npm: ["node_modules"], pnpm: ["node_modules/.pnpm"] }[install[0]];
        await sbx.exec(sandbox, ["bash", "-c", 'cd "$1"; shift; for path do test ! -e "$path" || exit 0; done; exit 1', "bash", value.repoDir, ...paths]);
      }
      await save(id, value);
      return value;
    } catch (error) {
      if (created) await sbx.call(["rm", "--force", sandbox]).catch(cleanup => {
        error.message += `\nIncomplete sandbox cleanup failed: ${cleanup.message}`;
      });
      throw error;
    }
  }

  async function exportCommit(id) {
    const value = await state(id);
    const repo = await canonicalRepo(config, value.repo);
    return transferFile(id, value.sandbox, async ({ sbx, local, remote }) => {
      await cleanCheckout(sbx, value);
      const head = commitSha(await sbx.exec(value.sandbox, ["git", "-C", value.repoDir, "rev-parse", "HEAD"]));
      if (head === value.baseSha) throw new Error("sandbox branch has no commits to export");
      const ref = `refs/sbx-work/imports/${id}/${head}`;
      await sbx.exec(value.sandbox, ["git", "-C", value.repoDir, "bundle", "create", remote, value.branch, `^${value.baseSha}`]);
      await sbx.copyFrom(value.sandbox, remote, local);
      await git(repo, "bundle", "verify", local);
      if (await git(repo, "bundle", "list-heads", local, `refs/heads/${value.branch}`) !== `${head} refs/heads/${value.branch}`) {
        throw new Error("bundle does not match the expected sandbox branch and HEAD");
      }
      await git(repo, "fetch", "--no-tags", local, `refs/heads/${value.branch}:${ref}`);
      if (await git(repo, "rev-parse", ref) !== head) throw new Error("imported commit does not match VM HEAD");
      const updated = { ...value, importedCommit: head, importedRef: ref };
      await save(id, updated);
      return { importedCommit: head, importedRef: ref };
    });
  }

  async function sync(id, commit) {
    commitSha(commit);
    const value = await state(id);
    await cleanCheckout(await createSbx(config), value);
    await sendCommit(id, value, commit);
    await save(id, { ...value, syncedCommit: commit });
    return { syncedCommit: commit };
  }

  return { inspect, seed, export: exportCommit, sync };
}
