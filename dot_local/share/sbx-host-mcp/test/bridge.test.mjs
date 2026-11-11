import assert from "node:assert/strict";
import { mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { createBridge } from "../lib/bridge.mjs";
import { fixture, git, log } from "./helpers.mjs";

test("mountless VM primitives need no repository or workflow registration", async t => {
  const paths = await fixture(t), { bridge } = paths;
  await bridge.create({ sandbox: "experiment" });
  assert.match((await bridge.list()).output, /experiment/);
  const invocation = await log(paths);
  assert.match(invocation, /--static-mcp.*none.*--skills.*off/);
  assert.doesNotMatch(invocation, /--clone/);
  const command = await bridge.exec({ sandbox: "experiment", cwd: paths.cwd("experiment"), script: 'printf "output\\n"; printf "failure detail\\n" >&2; exit 3' });
  assert.deepEqual(command, { exitCode: 3, output: "output\nfailure detail", stderr: "" });
  await bridge.remove({ sandbox: "experiment" });
  assert.equal((await bridge.list()).output, "");
  assert.match(await log(paths), /"command":"rm","args":\["--force","experiment"\]/);
});

test("foreground execution returns output directly without a job runner", async t => {
  const paths = await fixture(t), { bridge } = paths;
  await bridge.create({ sandbox: "experiment" });
  const noisy = await bridge.exec({ sandbox: "experiment", cwd: paths.cwd("experiment"), script: 'head -c 100000 /dev/zero | tr "\\0" x' });
  assert.equal(noisy.exitCode, 0);
  assert.equal(noisy.output.length, 100000);
  assert.deepEqual(await bridge.exec({ sandbox: "experiment", cwd: paths.cwd("experiment"), script: 'printf warning >&2' }), { exitCode: 0, output: "warning" });
  assert.doesNotMatch(await log(paths), /"command":"cp"/);
});

test("copies accept only staged regular files and never overwrite host files", async t => {
  const paths = await fixture(t), { bridge } = paths;
  await bridge.create({ sandbox: "experiment" });
  const remote = join(paths.cwd("experiment"), "input");
  await writeFile(join(paths.transfer, "input.bundle"), "committed input");
  await bridge.copy({ sandbox: "experiment", direction: "to", file: "input.bundle", vmPath: remote });
  const copied = await bridge.copy({ sandbox: "experiment", direction: "from", vmPath: remote });
  assert.equal(await readFile(copied.path, "utf8"), "committed input");
  const again = await bridge.copy({ sandbox: "experiment", direction: "from", vmPath: remote });
  assert.notEqual(again.file, copied.file);
  await symlink(join(paths.transfer, "input.bundle"), join(paths.transfer, "link"));
  for (const file of ["../secret", "/etc/passwd", "link"]) await assert.rejects(bridge.copy({ sandbox: "experiment", direction: "to", file, vmPath: remote }));
  await symlink(remote, `${remote}-link`);
  await assert.rejects(bridge.copy({ sandbox: "experiment", direction: "from", vmPath: `${remote}-link` }));
  await assert.rejects(bridge.copy({ sandbox: "experiment", direction: "from", vmPath: paths.cwd("experiment") }));
  await symlink(paths.transfer, join(paths.root, "linked-transfer"));
  const linked = await createBridge({ env: { ...paths.env, SBX_HOST_TRANSFER_ROOT: join(paths.root, "linked-transfer") } });
  await assert.rejects(linked.copy({ sandbox: "experiment", direction: "to", file: "input.bundle", vmPath: remote }));
});

test("private restore uses fixed package commands, process credentials, and disabled scripts", async t => {
  const paths = await fixture(t), { bridge } = paths;
  await bridge.create({ sandbox: "experiment" });
  const cwd = paths.cwd("experiment");
  await writeFile(join(cwd, "package-lock.json"), "{}");
  for (const manager of ["npm@10.0.0", "yarn@1.22.0", "yarn@4.0.0", "pnpm@9.0.0"]) {
    await writeFile(join(cwd, "package.json"), JSON.stringify({ packageManager: manager }));
    const outcome = await bridge.restore({ sandbox: "experiment", cwd, organization: "example" });
    assert.equal(outcome.exitCode, 0);
    const output = JSON.parse(outcome.output);
    assert.equal(output.tokenPresent, true);
    assert.equal(output.scripts, "true");
    assert.equal(output.yarnScripts, "false");
  }
  assert.doesNotMatch(await log(paths), /fixture-package-token/);
  assert.equal((await bridge.exec({ sandbox: "experiment", cwd, script: 'test -z "${ADO_NPM_TOKEN-}"' })).exitCode, 0);
  await writeFile(join(cwd, "package.json"), '{"packageManager":"evil@1"}');
  await assert.rejects(bridge.restore({ sandbox: "experiment", cwd, organization: "example" }), /supported packageManager/);
});

test("ordinary Git bundles support experiment checkout and exact result retrieval", async t => {
  const paths = await fixture(t), { bridge } = paths;
  const repo = join(paths.root, "repo");
  await mkdir(repo);
  await git(repo, "init", "-q");
  await git(repo, "config", "user.name", "Test");
  await git(repo, "config", "user.email", "test@example.com");
  await writeFile(join(repo, "baseline"), "baseline");
  await git(repo, "add", ".");
  await git(repo, "-c", "commit.gpgsign=false", "commit", "-qm", "Baseline");
  await git(repo, "bundle", "create", join(paths.transfer, "seed.bundle"), "HEAD");
  await bridge.create({ sandbox: "experiment" });
  const cwd = paths.cwd("experiment"), seed = join(cwd, "seed.bundle"), checkout = join(cwd, "repo");
  await bridge.copy({ sandbox: "experiment", direction: "to", file: "seed.bundle", vmPath: seed });
  const setup = await bridge.exec({ sandbox: "experiment", cwd, script: 'git clone -q seed.bundle repo && git -C repo remote remove origin' });
  assert.equal(setup.exitCode, 0);
  const outcome = await bridge.exec({ sandbox: "experiment", cwd: checkout, script: 'git config user.name Test; git config user.email test@example.com; printf result > result; git add result; git -c commit.gpgsign=false commit -qm Result; git bundle create ../result.bundle HEAD; git rev-parse HEAD' });
  assert.equal(outcome.exitCode, 0);
  const downloaded = await bridge.copy({ sandbox: "experiment", direction: "from", vmPath: join(cwd, "result.bundle") });
  await git(repo, "bundle", "verify", downloaded.path);
  await git(repo, "fetch", downloaded.path, "HEAD:refs/review/experiment");
  assert.equal(await git(repo, "rev-parse", "refs/review/experiment"), outcome.output.split("\n").at(-1));
  assert.equal(await git(repo, "status", "--porcelain"), "");
});
