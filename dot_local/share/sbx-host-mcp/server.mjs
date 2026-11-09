#!/usr/bin/env node

import { realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { createHelperClient } from "./lib/helper-client.mjs";
import { createSeedManager } from "./lib/seed-manager.mjs";
import { createTaskManager } from "./lib/task-manager.mjs";

const home = homedir();
const reposRoot = resolve(
  process.env.SBX_HOST_REPOS_ROOT || join(home, "repos"),
);
const stateRoot = resolve(
  process.env.SBX_HOST_STATE_ROOT ||
    join(process.env.XDG_STATE_HOME || join(home, ".local", "state"), "sbx-work"),
);
const tasksRoot = join(stateRoot, "tasks");
const packageRoot = dirname(fileURLToPath(import.meta.url));
const helper = resolve(
  process.env.SBX_HOST_HELPER || join(packageRoot, "sbx-work.sh"),
);

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

async function validateCanonicalRepo(repo) {
  const expected = resolve(reposRoot, repo);
  const resolved = await realpath(expected);
  if (resolved !== expected || !resolved.startsWith(`${reposRoot}${sep}`)) {
    throw new Error(`Repository must be a canonical clone under ${reposRoot}`);
  }
  const gitDir = await realpath(join(resolved, ".git"));
  if (gitDir !== join(resolved, ".git")) {
    throw new Error("Repository .git must be a directory in the canonical clone");
  }
}

const helperClient = createHelperClient({ helper, home });
const seedManager = createSeedManager({
  runHelper: helperClient.run,
  formatError: helperClient.formatError,
});
const taskManager = createTaskManager({
  helper,
  home,
  stateRoot,
  tasksRoot,
  runHelper: helperClient.run,
});

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
      waitSeconds: z.number().int().min(0).max(120).default(0),
    },
  },
  async ({ workItem, waitSeconds }) => {
    try {
      const seed = await seedManager.wait(workItem, waitSeconds);
      if (seed.state === "failed") return result(seed.error, true);
      if (seed.state === "running") {
        return result(JSON.stringify(seed.status, null, 2));
      }
      return result(await helperClient.run(["inspect", String(workItem)]));
    } catch (error) {
      return result(helperClient.formatError(error), true);
    }
  },
);

server.registerTool(
  "seed",
  {
    description:
      "Create a constrained native clone-mode Docker Sandbox and pre-restore detected Azure Artifacts dependencies before agent startup.",
    inputSchema: {
      workItem: workItemSchema,
      slug: slugSchema,
      repo: repoSchema,
    },
  },
  async ({ workItem, slug, repo }) => {
    try {
      await validateCanonicalRepo(repo);
      return result(
        JSON.stringify(seedManager.start(workItem, slug, repo), null, 2),
      );
    } catch (error) {
      return result(helperClient.formatError(error), true);
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
      return result(helperClient.formatError(error), true);
    }
  },
);

server.registerTool(
  "task_status",
  {
    description: "Read persisted status for one dispatched sandbox task.",
    inputSchema: { taskId: taskIdSchema },
  },
  async ({ taskId }) => {
    try {
      return result(JSON.stringify(await taskManager.read(taskId), null, 2));
    } catch (error) {
      return result(helperClient.formatError(error), true);
    }
  },
);

server.registerTool(
  "task_logs",
  {
    description: "Read the tail of one dispatched sandbox task log.",
    inputSchema: {
      taskId: taskIdSchema,
      tailBytes: z.number().int().min(1024).max(32768).default(16384),
    },
  },
  async ({ taskId, tailBytes }) => {
    try {
      return result(await taskManager.logs(taskId, tailBytes));
    } catch (error) {
      return result(helperClient.formatError(error), true);
    }
  },
);

server.registerTool(
  "cancel",
  {
    description: "Cancel one running dispatched sandbox task.",
    inputSchema: { taskId: taskIdSchema },
  },
  async ({ taskId }) => {
    try {
      return result(JSON.stringify(await taskManager.cancel(taskId), null, 2));
    } catch (error) {
      return result(helperClient.formatError(error), true);
    }
  },
);

for (const [name, description, command] of [
  [
    "export",
    "Export a clean committed sandbox branch to a standard host worktree and rebase it on the latest remote base.",
    "export",
  ],
  [
    "sync",
    "Synchronize the reviewed clean host branch back into the existing sandbox clone.",
    "sync",
  ],
]) {
  server.registerTool(
    name,
    {
      description,
      inputSchema: { workItem: workItemSchema },
    },
    async ({ workItem }) => {
      try {
        return result(await helperClient.run([command, String(workItem)]));
      } catch (error) {
        return result(helperClient.formatError(error), true);
      }
    },
  );
}

await server.connect(new StdioServerTransport());
