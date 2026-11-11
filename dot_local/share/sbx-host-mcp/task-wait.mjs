#!/usr/bin/env node

import { createTaskManager } from "./lib/task-manager.mjs";

try {
  const [tasksRoot, taskId, seconds = "1800", ...extra] = process.argv.slice(2);
  if (
    !tasksRoot ||
    !/^task-[a-f0-9-]{36}$/.test(taskId || "") ||
    !/^[1-9][0-9]*$/.test(seconds) ||
    Number(seconds) > 3600 ||
    extra.length > 0
  ) {
    throw new Error("Usage: task-wait TASK_ID [TIMEOUT_SECONDS (1-3600)]");
  }
  const manager = createTaskManager({ tasksRoot });
  const result = await manager.wait(taskId, Number(seconds) * 1000);
  if (!result.timedOut) {
    result.logTail = await manager.logs(taskId, 8192);
  }
  console.log(JSON.stringify(result, null, 2));
  if (result.timedOut) process.exitCode = 124;
  else process.exitCode = result.task.status === "completed" ? 0 : 1;
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
