import { once } from "node:events";
import { createInterface } from "node:readline";
import { createSbx } from "./sbx.mjs";

// Keep a session leader alive through cancellation so its process-group ID cannot be reused.
const runner = `
set -euo pipefail
prompt="$(cat)"
trap 'trap "" TERM INT; kill -TERM -- "-$$"; sleep 1; kill -KILL -- "-$$"' TERM INT
IFS= read -r stat <"/proc/$$/stat"
read -r -a fields <<<"\${stat##*) }"
printf 'SBX_TASK %s %s\\n' "$$" "\${fields[19]}"
export PATH="$HOME/.local/bin:$PATH"
copilot --yolo -p "$prompt" &
wait "$!"
`;
const cancel = `
set -euo pipefail
if ! IFS= read -r stat <"/proc/$1/stat"; then exit 0; fi
read -r -a fields <<<"\${stat##*) }"
[[ "\${fields[19]}" == "$2" ]] || { echo "VM task process identity changed" >&2; exit 1; }
kill -TERM -- "-$1"
`;
const stopped = `
ps -eo pgid=,stat= | awk -v group="$1" '$1 == group && $2 !~ /^Z/ { alive = 1 } END { exit alive }'
`;

export async function runAgent(config, task, prompt, signal) {
  if (signal.aborted) return { canceled: true };
  const sbx = await createSbx(config);
  const child = sbx.spawn(["exec", "-i", "-w", task.repoDir, task.sandbox, "--",
    "setsid", "--wait", "bash", "-lc", runner,
  ], { stdio: ["pipe", "pipe", "inherit"] });
  const closed = once(child, "close").then(result => ({ result }), error => ({ error }));
  child.stdin.on("error", error => { if (error.code !== "EPIPE") console.error(error.message); });
  child.stdin.end(prompt);
  const lines = createInterface({ input: child.stdout });
  let remote, cancellation, cancellationError;
  const cancelRemote = () => {
    if (!remote || cancellation) return;
    cancellation = sbx.exec(task.sandbox, ["bash", "-c", cancel, "bash", ...remote])
      .catch(error => { cancellationError = error; console.error(`Cancellation not confirmed: ${error.message}`); });
  };
  signal.addEventListener("abort", cancelRemote);
  try {
    for await (const line of lines) {
      if (!remote) {
        const match = /^SBX_TASK ([1-9][0-9]*) ([0-9]+)$/.exec(line);
        if (!match) { process.stdout.write(`${line}\n`); continue; }
        remote = match.slice(1);
        if (signal.aborted) cancelRemote();
      } else {
        process.stdout.write(`${line}\n`);
      }
    }
    const outcome = await closed;
    if (outcome.error) throw outcome.error;
    const [code] = outcome.result;
    if (!remote) throw new Error("VM task exited before acknowledging startup");
    if (signal.aborted) {
      await cancellation;
      if (cancellationError) throw cancellationError;
      await sbx.exec(task.sandbox, ["bash", "-c", stopped, "bash", remote[0]]);
      return { canceled: true };
    }
    if (code !== 0) throw Object.assign(new Error(`Copilot exited (${code})`), { exitCode: code || 1 });
    return { canceled: false };
  } finally {
    signal.removeEventListener("abort", cancelRemote);
    lines.close();
  }
}
