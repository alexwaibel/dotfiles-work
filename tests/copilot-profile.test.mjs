import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const source = fileURLToPath(new URL("..", import.meta.url));
const target = join(homedir(), ".local/share/sbx-copilot-profile/portable-copilot.yaml");
const render = path => execFileSync("chezmoi", ["cat", path], { cwd: source, encoding: "utf8" });

test("the sandbox profile reuses host defaults and only selected portable guidance", () => {
  const { copilot } = JSON.parse(readFileSync(join(source, ".chezmoidata/copilot.json"), "utf8"));
  const descriptor = render(target);
  const kit = JSON.parse(execFileSync("chezmoi", [
    "execute-template", "--with-stdin", "{{ fromYaml .chezmoi.stdin | toJson }}",
  ], { cwd: source, input: descriptor, encoding: "utf8" }));
  const files = new Map(kit.capabilities[0].config.files.map(file => [file.path, file.content]));
  const home = "/home/agent/.copilot";
  assert.deepEqual([...files.keys()], [
    `${home}/settings.json`, `${home}/copilot-instructions.md`,
    ...copilot.sandboxSkills.map(skill => `${home}/skills/${skill}/SKILL.md`),
  ]);
  assert.deepEqual(JSON.parse(files.get(`${home}/settings.json`)), copilot.defaults);
  const hostSettings = JSON.parse(render(join(homedir(), ".copilot/settings.json")));
  for (const [key, value] of Object.entries(copilot.defaults)) assert.equal(hostSettings[key], value);
  const shared = readFileSync(join(source, ".chezmoitemplates/copilot/portable-instructions.md"), "utf8").trim();
  assert.ok(render(join(homedir(), ".copilot/copilot-instructions.md")).includes(shared));
  assert.ok(files.get(`${home}/copilot-instructions.md`).includes(shared));
  for (const skill of copilot.sandboxSkills) {
    assert.equal(files.get(`${home}/skills/${skill}/SKILL.md`),
      readFileSync(join(source, `dot_copilot/skills/${skill}/SKILL.md`), "utf8"));
  }
});
