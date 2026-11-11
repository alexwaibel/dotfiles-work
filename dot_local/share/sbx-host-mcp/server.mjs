#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { configuration, formatError } from "./lib/runtime.mjs";
import { createSandbox } from "./lib/sandbox.mjs";
import { createTaskManager } from "./lib/tasks.mjs";

const config = configuration();
const sandbox = createSandbox(config);

const workItemSchema = z.number().int().positive();
const slugSchema = z
  .string()
  .regex(/^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?$/);
const repoSchema = z.string().regex(/^[A-Za-z0-9._-]+$/);
const taskIdSchema = z.string().regex(/^task-[a-f0-9-]{36}$/);

function result(text, isError = false) {
  return {
    content: [{ type: "text", text }],
    ...(isError ? { isError: true } : {}),
  };
}

const taskManager = createTaskManager(config);

const server = new McpServer({
  name: "sbx-host",
  version: "1.0.0",
});

server.registerTool(
  "inspect",
  {
    description:
      "Read allowlisted transfer metadata and report whether the registered Docker Sandbox still exists.",
    inputSchema: {
      workItem: workItemSchema,
    },
  },
  async ({ workItem }) => {
    try {
      const seed = await taskManager.find(workItem, { kind: "seed" });
      if (seed) {
        return result(JSON.stringify(seed, null, 2));
      }
      return result(JSON.stringify(await sandbox.inspect(workItem), null, 2));
    } catch (error) {
      return result(formatError(error), true);
    }
  },
);

server.registerTool(
  "seed",
  {
    description:
      "Start a persisted seed job that creates a mountless Docker Sandbox from committed Git objects and restores detected Azure Artifacts dependencies. Returns a taskId for task-wait, task_status, or task_logs.",
    inputSchema: {
      workItem: workItemSchema,
      slug: slugSchema,
      repo: repoSchema,
      reuseExistingBranch: z.boolean().default(false),
    },
  },
  async ({ workItem, slug, repo, reuseExistingBranch }) => {
    try {
      return result(
        JSON.stringify(
          await taskManager.startSeed(workItem, slug, repo, reuseExistingBranch),
          null,
          2,
        ),
      );
    } catch (error) {
      return result(formatError(error), true);
    }
  },
);

server.registerTool(
  "dispatch",
  {
    description:
      "Start one noninteractive Copilot task inside an existing work-item sandbox.",
    inputSchema: {
      workItem: workItemSchema,
      prompt: z.string().min(1).max(32000),
    },
  },
  async ({ workItem, prompt }) => {
    try {
      return result(
        JSON.stringify(await taskManager.dispatch(workItem, prompt), null, 2),
      );
    } catch (error) {
      return result(formatError(error), true);
    }
  },
);

server.registerTool(
  "task_status",
  {
    description: "Read persisted status for one seed or Copilot task.",
    inputSchema: { taskId: taskIdSchema },
  },
  async ({ taskId }) => {
    try {
      return result(JSON.stringify(await taskManager.read(taskId), null, 2));
    } catch (error) {
      return result(formatError(error), true);
    }
  },
);

server.registerTool(
  "task_logs",
  {
    description: "Read the tail of one seed or Copilot task log.",
    inputSchema: {
      taskId: taskIdSchema,
      tailBytes: z.number().int().min(1024).max(32768).default(16384),
    },
  },
  async ({ taskId, tailBytes }) => {
    try {
      return result(await taskManager.logs(taskId, tailBytes));
    } catch (error) {
      return result(formatError(error), true);
    }
  },
);

server.registerTool(
  "cancel",
  {
    description: "Signal a running task inside its VM and confirm its process group has stopped.",
    inputSchema: { taskId: taskIdSchema },
  },
  async ({ taskId }) => {
    try {
      return result(JSON.stringify(await taskManager.cancel(taskId), null, 2));
    } catch (error) {
      return result(formatError(error), true);
    }
  },
);

server.registerTool(
  "export",
  {
    description:
      "Verify and import the exact committed sandbox branch using a Git bundle. Does not fetch origin, modify host worktrees, or integrate Git history.",
    inputSchema: { workItem: workItemSchema },
  },
  async ({ workItem }) => {
    try {
      return result(JSON.stringify(await taskManager.export(workItem), null, 2));
    } catch (error) {
      return result(formatError(error), true);
    }
  },
);

server.registerTool(
  "sync",
  {
    description:
      "Copy an explicit host commit into the clean sandbox checkout. Does not fetch origin or choose Git history.",
    inputSchema: {
      workItem: workItemSchema,
      commit: z.string().regex(/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/),
    },
  },
  async ({ workItem, commit }) => {
    try {
      return result(JSON.stringify(await taskManager.sync(workItem, commit), null, 2));
    } catch (error) {
      return result(formatError(error), true);
    }
  },
);

await server.connect(new StdioServerTransport());
