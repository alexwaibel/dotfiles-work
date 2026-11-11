#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { createBridge } from "./lib/bridge.mjs";

const bridge = await createBridge();
const server = new McpServer({ name: "sbx-host", version: "3.0.0" });
const sandbox = z.string().regex(/^[a-z0-9][a-z0-9.-]{1,62}$/);
const path = z.string().min(1).max(4096);
/** Expose a bridge operation with JSON responses and MCP error reporting. */
function register(name, description, inputSchema) {
  server.registerTool(name, { description, inputSchema }, async input => {
    try {
      return { content: [{ type: "text", text: JSON.stringify(await bridge[name](input)) }] };
    } catch (error) {
      return { content: [{ type: "text", text: error.message }], isError: true };
    }
  });
}
register("list", "List native Docker sandboxes. No workflow registration is required.", {});
register("create", "Create and start a mountless Copilot VM with its curated portable profile, without the global shared-skills store or external MCP access.", { sandbox });
register("exec", "Run a foreground shell script inside a VM and return output and exitCode. For nonblocking work, explicitly background the command with redirected stdin/stdout/stderr and record its log, PID, and exit-code file.", {
  sandbox, script: z.string().min(1).max(64000), cwd: path,
});
register("copy", "Copy one regular file to/from a VM. Host files are restricted to ~/repos/.sbx-transfer (or SBX_HOST_TRANSFER_ROOT). Uploads use a staged filename; downloads create a new filename and never overwrite host files.", {
  sandbox, direction: z.enum(["to", "from"]), vmPath: path, file: z.string().min(1).max(200).optional(),
});
register("restore", "Run a foreground Yarn/npm/pnpm restore with an Azure Artifacts package-read token and lifecycle scripts disabled. Returns output and exitCode; credentials are passed only through the process environment.", {
  sandbox, cwd: path, organization: z.string().regex(/^[A-Za-z0-9._-]+$/),
});
register("stop", "Stop a named VM, including its running commands. Repository files remain.", { sandbox });
register("remove", "Remove a named VM and its contents. Retrieve needed results first.", { sandbox });
await server.connect(new StdioServerTransport());
