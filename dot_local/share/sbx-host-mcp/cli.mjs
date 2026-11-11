#!/usr/bin/env node
import { createTaskManager } from "./lib/tasks.mjs";

try {
  const [command, id, seconds = "1800", ...extra] = process.argv.slice(2);
  if (command === "--help" || command === "-h") {
    console.log("Usage: sbx-work task-wait TASK_ID [TIMEOUT_SECONDS (1-3600)]\nUse sbx-host MCP for sandbox preparation, dispatch, inspection and transfer; native sbx for lifecycle.");
  } else {
    if (command !== "task-wait" || !/^[1-9][0-9]*$/.test(seconds) || Number(seconds) > 3600 || extra.length) {
      throw new Error("Usage: sbx-work task-wait TASK_ID [TIMEOUT_SECONDS (1-3600)]");
    }
    const tasks = createTaskManager();
    const result = await tasks.wait(id, Number(seconds) * 1000);
    if (!result.timedOut) result.logTail = await tasks.logs(id, 8192);
    console.log(JSON.stringify(result, null, 2));
    process.exitCode = result.timedOut ? 124 : result.task.status === "completed" ? 0 : 1;
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
