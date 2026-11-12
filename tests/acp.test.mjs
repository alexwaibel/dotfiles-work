import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

test("acp defaults to interactive execution and preserves explicit mode choices", t => {
  const root = mkdtempSync(join(tmpdir(), "acp-mode-test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const source = fileURLToPath(new URL("../dot_local/bin/executable_acp.tmpl", import.meta.url));
  const rendered = execFileSync("chezmoi", [
    "execute-template", "--file", source,
    "--override-data", '{"mcpTool":{"command":"acp-test-copilot"}}',
  ], { encoding: "utf8" });
  const launcher = join(root, "acp");
  writeFileSync(launcher, rendered);
  writeFileSync(join(root, "acp-test-copilot"),
    `#!${process.execPath}\nconsole.log(JSON.stringify(process.argv.slice(2)));\n`, { mode: 0o700 });
  const invoke = args => JSON.parse(execFileSync("bash", [launcher, ...args], {
    env: { ...process.env, PATH: `${root}:${process.env.PATH}` }, encoding: "utf8",
  }));
  const defaults = invoke([]);
  assert.deepEqual(defaults.slice(0, 3), ["copilot", "--mode", "interactive"]);
  assert.ok(!defaults.includes("--autopilot"));
  assert.ok(defaults.includes("--allow-tool=write"));
  for (const flags of [["--autopilot"], ["--mode", "autopilot"], ["--mode=plan"], ["--plan"]]) {
    const args = invoke(flags);
    assert.ok(!args.includes("interactive"));
    assert.deepEqual(args.slice(-flags.length), flags);
  }
  assert.deepEqual(invoke(["--", "--autopilot"]).slice(0, 3), ["copilot", "--mode", "interactive"]);
  assert.deepEqual(invoke(["--prompt", "--autopilot"]).slice(0, 3), ["copilot", "--mode", "interactive"]);
});
