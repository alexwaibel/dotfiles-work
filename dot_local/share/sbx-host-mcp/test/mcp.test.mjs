import assert from "node:assert/strict";
import { once } from "node:events";
import { test } from "node:test";
import { fixture, startServer } from "./helpers.mjs";

test("MCP exposes direct execution and explicitly backgrounded work survives client restart", async t => {
  const paths = await fixture(t);
  const first = startServer(t, paths);
  await first.initialize();
  const tools = await first.request("tools/list", {});
  assert.deepEqual(tools.result.tools.map(tool => tool.name).sort(), ["copy", "create", "exec", "list", "remove", "restore", "stop"]);
  await first.call("create", { sandbox: "experiment" });
  const command = await first.call("exec", { sandbox: "experiment", cwd: paths.cwd("experiment"), script: 'nohup bash -c \'sleep 1; printf "survived\\n"; printf "7\\n" > exit.code\' > output.log 2>&1 < /dev/null & echo $!' });
  assert.equal(command.exitCode, 0);
  assert.match(command.output, /^[1-9][0-9]*$/);
  const stopped = once(first.child, "close");
  first.child.kill();
  await stopped;
  const second = startServer(t, paths);
  await second.initialize();
  const outcome = await second.call("exec", { sandbox: "experiment", cwd: paths.cwd("experiment"), script: 'timeout 5 bash -c \'until test -f exit.code; do sleep .1; done\' && cat exit.code output.log' });
  assert.equal(outcome.exitCode, 0);
  assert.equal(outcome.output, "7\nsurvived");
  for (const [tool, input] of [
    ["create", { sandbox: "../escape" }],
    ["exec", { sandbox: "experiment", cwd: "relative", script: "true" }],
    ["result", { sandbox: "experiment", commandId: "removed-operation" }],
    ["copy", { sandbox: "experiment", direction: "to", vmPath: "/tmp/a", file: "../secret" }],
  ]) await assert.rejects(second.call(tool, input));
});
