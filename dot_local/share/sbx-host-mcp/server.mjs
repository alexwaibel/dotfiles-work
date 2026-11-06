#!/usr/bin/env node

import { execFile } from "node:child_process";
import { realpath, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const execFileAsync = promisify(execFile);
const home = homedir();
const reposRoot = resolve(
  process.env.SBX_HOST_REPOS_ROOT || join(home, "repos"),
);
const stateRoot = resolve(
  process.env.SBX_HOST_STATE_ROOT ||
    join(process.env.XDG_STATE_HOME || join(home, ".local", "state"), "sbx-work"),
);
const packageRoot = dirname(fileURLToPath(import.meta.url));
const helper = resolve(
  process.env.SBX_HOST_HELPER || join(packageRoot, "sbx-work.sh"),
);
const maxBuffer = 8 * 1024 * 1024;
const maxResult = 32 * 1024;
const timeout = 15 * 60 * 1000;

const workItemSchema = z.number().int().positive();
const slugSchema = z
  .string()
  .regex(/^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?$/);
const repoSchema = z.string().regex(/^[A-Za-z0-9._-]+$/);

function result(text, isError = false) {
  return {
    content: [{ type: "text", text }],
    ...(isError ? { isError: true } : {}),
  };
}

function formatError(error) {
  if (error && typeof error === "object") {
    const stderr = typeof error.stderr === "string" ? error.stderr.trim() : "";
    const stdout = typeof error.stdout === "string" ? error.stdout.trim() : "";
    const message = error instanceof Error ? error.message : String(error);
    return truncateOutput([message, stderr, stdout].filter(Boolean).join("\n"));
  }
  return String(error);
}

function truncateOutput(text) {
  if (text.length <= maxResult) return text;
  return `[output truncated to final ${maxResult} bytes]\n${text.slice(-maxResult)}`;
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
  return resolved;
}

async function runHelper(args) {
  const { stdout, stderr } = await execFileAsync("/usr/bin/bash", [helper, ...args], {
    cwd: home,
    encoding: "utf8",
    maxBuffer,
    timeout,
    windowsHide: true,
  });
  return truncateOutput(
    [stdout.trim(), stderr.trim()].filter(Boolean).join("\n"),
  );
}

async function inspectState(workItem) {
  const statePath = join(stateRoot, `${workItem}.json`);
  const parsed = JSON.parse(await readFile(statePath, "utf8"));
  const allowedKeys = [
    "workItem",
    "slug",
    "repo",
    "sandbox",
    "branch",
    "baseBranch",
    "baseSha",
    "repoDir",
    "hostWorktree",
    "exportedCommit",
    "syncedCommit",
  ];
  return Object.fromEntries(
    allowedKeys
      .filter(key => Object.hasOwn(parsed, key))
      .map(key => [key, parsed[key]]),
  );
}

const server = new McpServer({
  name: "sbx-host",
  version: "1.0.0",
});

server.registerTool(
  "inspect",
  {
    description:
      "Read sbx-work transfer metadata for one work item. Does not execute Docker or modify files.",
    inputSchema: { workItem: workItemSchema },
  },
  async ({ workItem }) => {
    try {
      return result(JSON.stringify(await inspectState(workItem), null, 2));
    } catch (error) {
      return result(formatError(error), true);
    }
  },
);

server.registerTool(
  "seed",
  {
    description:
      "Create a constrained mountless Docker Sandbox seed and pre-restore detected Azure Artifacts dependencies before agent startup.",
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
        await runHelper(["seed", String(workItem), slug, repo]),
      );
    } catch (error) {
      return result(formatError(error), true);
    }
  },
);

server.registerTool(
  "export",
  {
    description:
      "Export a clean committed sandbox branch to a standard host worktree and rebase it on the latest remote base.",
    inputSchema: { workItem: workItemSchema },
  },
  async ({ workItem }) => {
    try {
      return result(await runHelper(["export", String(workItem)]));
    } catch (error) {
      return result(formatError(error), true);
    }
  },
);

server.registerTool(
  "sync",
  {
    description:
      "Synchronize the rebased clean host branch back into the existing sandbox clone.",
    inputSchema: { workItem: workItemSchema },
  },
  async ({ workItem }) => {
    try {
      return result(await runHelper(["sync", String(workItem)]));
    } catch (error) {
      return result(formatError(error), true);
    }
  },
);

const transport = new StdioServerTransport();
await server.connect(transport);
