import assert from "node:assert/strict";
import { test } from "node:test";
import { run } from "../lib/runtime.mjs";

test("run passes stdin and literal arguments and returns trimmed stdout", async () => {
  const script = 'process.stdin.setEncoding("utf8"); let input=""; process.stdin.on("data",chunk=>input+=chunk); process.stdin.on("end",()=>console.log(JSON.stringify({input,arg:process.argv[1],cwd:process.cwd(),value:process.env.RUN_TEST})));';
  const value = JSON.parse(await run(process.execPath, ["-e", script, "$(not-a-shell-command)"], {
    input: "task\ninstructions", cwd: "/tmp", env: { ...process.env, RUN_TEST: "example" },
  }));
  assert.deepEqual(value, { input: "task\ninstructions", arg: "$(not-a-shell-command)", cwd: "/tmp", value: "example" });
});

test("run closes stdin even without input and tolerates a child that exits without reading", async () => {
  assert.equal(await run(process.execPath, ["-e", 'process.stdin.resume(); process.stdin.on("end",()=>console.log("done"));']), "done");
  assert.equal(await run(process.execPath, ["-e", 'console.log("done"); process.exit(0)'], { input: "x".repeat(2 * 1024 * 1024) }), "done");
});

test("run rejects unsuccessful execution with native diagnostics", async () => {
  await assert.rejects(run(process.execPath, ["-e", 'console.error("failure detail"); process.exit(7)']), error => error.code === 7 && error.stderr.includes("failure detail"));
  await assert.rejects(run("/missing-sbx-test-executable", []), { code: "ENOENT" });
});

test("run rejects output exceeding its buffer instead of silently truncating it", async () => {
  await assert.rejects(run(process.execPath, ["-e", 'process.stdout.write("x".repeat(9 * 1024 * 1024))']), { code: "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" });
});
