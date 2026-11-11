import assert from "node:assert/strict";
import { test } from "node:test";
import { createSandbox } from "../lib/sandbox.mjs";
import { createSbx } from "../lib/sbx.mjs";
import { createTaskManager } from "../lib/tasks.mjs";
import { git } from "../lib/runtime.mjs";
import { commit, fixture, waitForLog } from "./helpers.mjs";

test("native mountless seed, exact transfers, and confirmed remote process-group cancellation", {
  skip: process.env.SBX_HOST_LIVE_TEST !== "1", timeout: 180000,
}, async t => {
  const paths = await fixture(t);
  paths.env.PATH = process.env.PATH;
  delete paths.env.SBX_WORK_SBX_BIN;
  if (process.env.SBX_HOST_LIVE_BIN) paths.env.SBX_WORK_SBX_BIN = process.env.SBX_HOST_LIVE_BIN;
  const sbx = await createSbx(paths.config);
  const tasks = createTaskManager(paths.config);
  const id = 9000000000000 + process.pid;
  const name = `wi-${id}-vm`;
  t.after(() => sbx.call(["rm", "--force", name]));
  const started = await tasks.startSeed(id, "bridge-smoke", "example-repo", false);
  const result = await tasks.wait(started.taskId, 120000);
  assert.equal(result.task.status, "completed", await tasks.logs(started.taskId));
  const state = await createSandbox(paths.config).inspect(id);
  assert.equal(await sbx.exec(name, ["git", "-C", state.repoDir, "rev-parse", "HEAD"]), state.baseSha);
  assert.equal(await sbx.exec(name, ["git", "-C", state.repoDir, "remote", "-v"]), "");
  await sbx.exec(name, ["test", "!", "-e", "/run/sandbox/source"]);
  await sbx.exec(name, ["bash", "-c",
    'cd "$1"; printf "VM change\\n" > live.txt; git add live.txt; git -c commit.gpgsign=false commit -qm "Live transfer fixture"',
    "bash", state.repoDir]);
  const exported = await tasks.export(id);
  assert.equal(await git(paths.repo, "rev-parse", exported.importedRef), exported.importedCommit);
  const followup = await commit(paths.repo, "host-followup.txt");
  assert.deepEqual(await tasks.sync(id, followup), { syncedCommit: followup });
  assert.equal(await sbx.exec(name, ["git", "-C", state.repoDir, "rev-parse", "HEAD"]), followup);
  await sbx.call(["exec", "-i", name, "--", "bash", "-c",
    'mkdir -p "$HOME/.local/bin"; cat > "$HOME/.local/bin/copilot"; chmod 700 "$HOME/.local/bin/copilot"',
  ], { input: '#!/bin/bash\ntrap "" TERM\nsleep 120 &\necho "agent-child=$!"\nwait "$!"\n' });
  const running = await tasks.dispatch(id, "Deterministic cancellation fixture");
  const [, child] = await waitForLog(paths, running.taskId, /agent-child=(\d+)/, 30000);
  assert.equal((await tasks.cancel(running.taskId)).status, "canceled");
  const childState = await sbx.exec(name, ["bash", "-c",
    'if test -r "/proc/$1/stat"; then stat="$(cat "/proc/$1/stat")"; read -r state _ <<<"${stat##*) }"; printf "%s" "$state"; else printf gone; fi',
    "bash", child]);
  assert.match(childState, /^(gone|Z)$/);
});
