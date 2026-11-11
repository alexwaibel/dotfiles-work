import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

test("host attachments exposes only constrained screenshot reads", async t => {
  const root = await mkdtemp(join(tmpdir(), "host-attachments-"));
  const attachments = join(root, "attachments");
  await mkdir(attachments);
  const screenshot = join(attachments, "copilot-image-test.png");
  await writeFile(screenshot, Buffer.from("89504e470d0a1a0a", "hex"));

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ["attachments-server.mjs"],
    cwd: new URL("..", import.meta.url),
    env: { ...process.env, HOST_ATTACHMENTS_ROOT: attachments },
  });
  const client = new Client({ name: "test", version: "1.0.0" });
  await client.connect(transport);
  t.after(() => client.close());

  const tools = await client.listTools();
  assert.deepEqual(tools.tools.map(tool => tool.name), ["read_screenshot"]);

  const response = await client.callTool({
    name: "read_screenshot",
    arguments: { path: screenshot },
  });
  assert.equal(response.isError, undefined);
  assert.equal(response.content[0].type, "image");
  assert.equal(response.content[0].mimeType, "image/png");

  const invalid = await client.callTool({
    name: "read_screenshot",
    arguments: { path: join(root, "secret.png") },
  });
  assert.equal(invalid.isError, true);
});
