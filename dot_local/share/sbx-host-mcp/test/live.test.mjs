import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { createBridge } from "../lib/bridge.mjs";
import { createSbx } from "../lib/sbx.mjs";
import { fixture, git } from "./helpers.mjs";

test("native VM creation, repository setup, execution, retrieval and stop cancellation", {
  skip: process.env.SBX_HOST_LIVE_TEST !== "1", timeout: 180000,
}, async t => {
  const paths = await fixture(t);
  const env = { ...paths.env, PATH: process.env.PATH };
  delete env.SBX_WORK_SBX_BIN;
  const bridge = await createBridge({ env }), sbx = await createSbx({ env });
  const sandbox = `sbx-primitive-smoke-${process.pid}`;
  t.after(() => bridge.remove({ sandbox }));
  const repo = join(paths.root, "repo");
  await mkdir(repo);
  await git(repo, "init", "-q");
  await git(repo, "config", "user.name", "Test");
  await git(repo, "config", "user.email", "test@example.com");
  await writeFile(join(repo, "baseline"), "baseline");
  await git(repo, "add", ".");
  await git(repo, "-c", "commit.gpgsign=false", "commit", "-qm", "Baseline");
  await git(repo, "bundle", "create", join(paths.transfer, "seed.bundle"), "HEAD");
  await bridge.create({ sandbox });
  assert.equal(await sbx.exec(sandbox, ["cat", "/tmp/portable-profile-fixture"]), "installed");
  await bridge.copy({ sandbox, direction: "to", file: "seed.bundle", vmPath: "/tmp/seed.bundle" });
  const setup = await bridge.exec({ sandbox, cwd: "/tmp", script: 'git clone -q seed.bundle repo && git -C repo remote remove origin && test ! -e /run/sandbox/source' });
  assert.equal(setup.exitCode, 0);
  const work = await bridge.exec({ sandbox, cwd: "/tmp/repo", script: 'printf result > result.txt; git diff --no-index /dev/null result.txt > /tmp/result.patch; test -s /tmp/result.patch' });
  assert.equal(work.exitCode, 0);
  assert.equal(await sbx.exec(sandbox, ["git", "-C", "/tmp/repo", "remote", "-v"]), "");
  assert.match(await sbx.exec(sandbox, ["copilot", "--version"]), /Copilot CLI/);
  const downloaded = await bridge.copy({ sandbox, direction: "from", vmPath: "/tmp/result.patch" });
  assert.match(await readFile(downloaded.path, "utf8"), /\+result/);
  const background = await bridge.exec({ sandbox, cwd: "/tmp/repo", script: 'nohup bash -c \'sleep 1; printf done > /tmp/background.log; printf "0\\n" > /tmp/background.exit\' > /tmp/background.output 2>&1 < /dev/null & echo $!' });
  assert.equal(background.exitCode, 0);
  assert.match(background.output, /^[1-9][0-9]*$/);
  const outcome = await bridge.exec({ sandbox, cwd: "/tmp/repo", script: 'timeout 5 bash -c \'until test -f /tmp/background.exit; do sleep .1; done\' && cat /tmp/background.exit /tmp/background.log' });
  assert.deepEqual(outcome, { exitCode: 0, output: "0\ndone" });
  const running = await bridge.exec({ sandbox, cwd: "/tmp/repo", script: 'nohup sleep 120 > /tmp/sleep.log 2>&1 < /dev/null & echo $!' });
  assert.equal(running.exitCode, 0);
  assert.equal(await sbx.exec(sandbox, ["kill", "-0", running.output]), "");
  await bridge.stop({ sandbox });
  assert.match((await bridge.list()).output, new RegExp(`${sandbox}[^\\n]*stopped`));
});
