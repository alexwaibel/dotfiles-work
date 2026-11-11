#!/usr/bin/env node

import { constants } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import { resolve, sep } from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const screenshotRoot = process.env.HOST_ATTACHMENTS_ROOT
  ? resolve(process.env.HOST_ATTACHMENTS_ROOT)
  : undefined;

function errorResult(error) {
  return {
    content: [
      {
        type: "text",
        text: error instanceof Error ? error.message : String(error),
      },
    ],
    isError: true,
  };
}

async function readScreenshot(path) {
  if (!screenshotRoot) {
    throw new Error("Screenshot reading is not configured");
  }
  const requested = resolve(path);
  const name = requested.slice(requested.lastIndexOf(sep) + 1);
  if (!requested.startsWith(`${screenshotRoot}${sep}`)) {
    throw new Error("Screenshot is outside the configured attachment directory");
  }
  if (!/^copilot-image-[A-Za-z0-9._-]+\.(png|jpe?g|webp)$/i.test(name)) {
    throw new Error("Only Copilot image attachments are allowed");
  }
  const metadata = await lstat(requested);
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new Error("Screenshot must be a regular file");
  }
  const resolved = await realpath(requested);
  const resolvedRoot = await realpath(screenshotRoot);
  if (!resolved.startsWith(`${resolvedRoot}${sep}`)) {
    throw new Error("Screenshot is outside the configured attachment directory");
  }
  const extension = name.toLowerCase().split(".").pop();
  const mimeType =
    extension === "png"
      ? "image/png"
      : extension === "webp"
        ? "image/webp"
        : "image/jpeg";
  const handle = await open(requested, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const openedMetadata = await handle.stat();
    if (!openedMetadata.isFile()) {
      throw new Error("Screenshot must be a regular file");
    }
    if (openedMetadata.size > 20 * 1024 * 1024) {
      throw new Error("Screenshot exceeds the 20 MiB limit");
    }
    return {
      data: (await handle.readFile()).toString("base64"),
      mimeType,
    };
  } finally {
    await handle.close();
  }
}

const server = new McpServer({
  name: "host-attachments",
  version: "1.0.0",
});

server.registerTool(
  "read_screenshot",
  {
    description:
      "Read a user-attached Copilot screenshot from the configured Windows temporary attachment directory.",
    inputSchema: { path: z.string().min(1).max(4096) },
  },
  async ({ path }) => {
    try {
      const image = await readScreenshot(path);
      return {
        content: [
          { type: "image", data: image.data, mimeType: image.mimeType },
          { type: "text", text: "Screenshot loaded from the user attachment." },
        ],
      };
    } catch (error) {
      return errorResult(error);
    }
  },
);

await server.connect(new StdioServerTransport());
