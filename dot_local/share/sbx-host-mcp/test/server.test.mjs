import assert from "node:assert/strict";
import { test } from "node:test";
import {
  fixture,
  initialize,
  readMessage,
  send,
  startServer,
} from "./mcp-test-helpers.mjs";

test("lists the constrained tool surface", async t => {
  const paths = await fixture();
  const process = startServer(paths);
  t.after(() => process.kill());
  await initialize(process);
  send(process, { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
  const response = await readMessage(process);
  assert.deepEqual(
    response.result.tools.map(tool => tool.name).sort(),
    [
      "cancel",
      "dispatch",
      "export",
      "inspect",
      "seed",
      "sync",
      "task_logs",
      "task_status",
    ],
  );
});

test("inspect returns only allowlisted metadata", async t => {
  const paths = await fixture();
  const process = startServer(paths);
  t.after(() => process.kill());
  await initialize(process);
  send(process, {
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: { name: "inspect", arguments: { workItem: 123 } },
  });
  const response = await readMessage(process);
  const text = response.result.content[0].text;
  assert.match(text, /wi-123-vm/);
  assert.match(text, /"sandboxStatus":"present"/);
  assert.doesNotMatch(text, /must-not-leak/);
});

test("seed returns immediately and inspect waits for completion", async t => {
  const paths = await fixture();
  const process = startServer(paths);
  t.after(() => process.kill());
  await initialize(process);
  const started = Date.now();
  send(process, {
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: {
      name: "seed",
      arguments: {
        workItem: 123,
        slug: "slow-seed",
        repo: "example-repo",
      },
    },
  });
  const response = await readMessage(process);
  assert.equal(response.result.isError, undefined);
  assert.ok(Date.now() - started < 750);
  assert.match(response.result.content[0].text, /"seedStatus": "running"/);
  assert.doesNotMatch(response.result.content[0].text, /repoDir/);

  send(process, {
    jsonrpc: "2.0",
    id: 3,
    method: "tools/call",
    params: {
      name: "inspect",
      arguments: { workItem: 123, waitSeconds: 2 },
    },
  });
  const completed = await readMessage(process);
  assert.equal(completed.result.isError, undefined);
  assert.match(completed.result.content[0].text, /"sandboxStatus":"present"/);

  send(process, {
    jsonrpc: "2.0",
    id: 4,
    method: "tools/call",
    params: {
      name: "seed",
      arguments: {
        workItem: 123,
        slug: "../escape",
        repo: "example-repo",
      },
    },
  });
  const invalid = await readMessage(process);
  assert.equal(invalid.result.isError, true);
});

test("failed helper output is bounded", async t => {
  const paths = await fixture();
  const process = startServer(paths);
  t.after(() => process.kill());
  await initialize(process);

  send(process, {
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: { name: "sync", arguments: { workItem: 999 } },
  });
  const response = await readMessage(process);
  const text = response.result.content[0].text;
  assert.equal(response.result.isError, true);
  assert.match(text, /output truncated/);
  assert.ok(text.length < 34 * 1024);
});
