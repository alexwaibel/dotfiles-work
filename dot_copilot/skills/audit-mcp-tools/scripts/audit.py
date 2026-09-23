#!/usr/bin/env python3
"""Audit pinned MCP tools against rendered configuration and live servers."""

import argparse
import json
import os
import selectors
import subprocess
import sys
import time
from pathlib import Path


DEFAULT_CONFIG = Path.home() / ".copilot" / "mcp-config.json"
DEFAULT_MANIFEST = Path.home() / ".config" / "acp" / "mcp-tools.json"
PROTOCOL_VERSION = "2025-06-18"


class McpError(RuntimeError):
    pass


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError as error:
        raise McpError(f"File not found: {path}") from error
    except json.JSONDecodeError as error:
        raise McpError(f"Invalid JSON in {path}: {error}") from error


def read_message(process: subprocess.Popen, timeout: float) -> dict:
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout

    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise McpError("Timed out waiting for MCP response")
        if process.poll() is not None:
            stderr = process.stderr.read().strip()
            raise McpError(
                f"MCP server exited with code {process.returncode}"
                + (f": {stderr}" if stderr else "")
            )

        events = selector.select(remaining)
        if not events:
            continue

        line = process.stdout.readline()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(message, dict):
            return message


def request(process: subprocess.Popen, request_id: int, method: str, params: dict) -> None:
    message = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
        "params": params,
    }
    process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    process.stdin.flush()


def notify(process: subprocess.Popen, method: str, params: dict) -> None:
    message = {"jsonrpc": "2.0", "method": method, "params": params}
    process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    process.stdin.flush()


def wait_for_response(process: subprocess.Popen, request_id: int, timeout: float) -> dict:
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise McpError(f"Timed out waiting for response {request_id}")
        message = read_message(process, remaining)
        if message.get("id") != request_id:
            continue
        if "error" in message:
            raise McpError(f"MCP error: {message['error']}")
        return message.get("result", {})


def list_live_tools(name: str, config: dict, timeout: float) -> set[str]:
    if config.get("type", "local") != "local":
        raise McpError("Only local stdio MCP servers are currently supported")

    command = config.get("command")
    if not command:
        raise McpError("Missing command")

    environment = os.environ.copy()
    environment.update(config.get("env", {}))
    process = subprocess.Popen(
        [command, *config.get("args", [])],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=environment,
    )

    try:
        request(
            process,
            1,
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "copilot-mcp-audit", "version": "1"},
            },
        )
        wait_for_response(process, 1, timeout)
        notify(process, "notifications/initialized", {})

        tools = set()
        cursor = None
        request_id = 2
        while True:
            params = {"cursor": cursor} if cursor else {}
            request(process, request_id, "tools/list", params)
            result = wait_for_response(process, request_id, timeout)
            tools.update(tool["name"] for tool in result.get("tools", []))
            cursor = result.get("nextCursor")
            if not cursor:
                return tools
            request_id += 1
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)


def audit_server(
    name: str,
    server: dict,
    manifest: dict,
    timeout: float,
    skip_live: bool,
) -> tuple[bool, dict]:
    configured = set(server.get("tools", []))
    expected = set(manifest.get("all", []))
    safe = set(manifest.get("safe", []))
    high_risk = manifest.get("highRisk", {})
    manual_approval = configured - safe

    result = {
        "configuredNotInventoried": sorted(configured - expected),
        "inventoriedNotConfigured": sorted(expected - configured),
        "safeNotConfigured": sorted(safe - configured),
        "manualApprovalConfigured": {
            tool: high_risk.get(
                tool, "Not classified as read-oriented; review before auto-approving."
            )
            for tool in sorted(manual_approval)
        },
    }

    if not skip_live:
        live = list_live_tools(name, server, timeout)
        result["liveNotConfigured"] = sorted(live - configured)
        result["configuredNotLive"] = sorted(configured - live)

    drift_keys = (
        "configuredNotInventoried",
        "inventoriedNotConfigured",
        "safeNotConfigured",
        "liveNotConfigured",
        "configuredNotLive",
    )
    has_drift = any(result.get(key) for key in drift_keys)
    return has_drift, result


def print_server(name: str, result: dict) -> None:
    print(f"\n{name}")
    print("-" * len(name))
    labels = {
        "configuredNotInventoried": "Configured but absent from inventory",
        "inventoriedNotConfigured": "Inventoried but not configured",
        "safeNotConfigured": "Safe tools missing from configuration",
        "liveNotConfigured": "NEW live tools disabled by configuration",
        "configuredNotLive": "Configured tools no longer offered",
    }
    for key, label in labels.items():
        values = result.get(key, [])
        if values:
            print(f"{label}:")
            for value in values:
                print(f"  - {value}")

    manual_approval = result.get("manualApprovalConfigured", {})
    if manual_approval:
        print("Configured tools requiring explicit approval:")
        for tool, reason in sorted(manual_approval.items()):
            print(f"  - {tool}: {reason}")

    if not any(result.get(key) for key in labels):
        print("No MCP inventory drift detected.")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compare pinned MCP tools with configured and live server surfaces."
    )
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--server", action="append", dest="servers")
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument(
        "--skip-live",
        action="store_true",
        help="Compare the manifest and rendered config without starting MCP servers.",
    )
    parser.add_argument("--json", action="store_true", dest="json_output")
    args = parser.parse_args()

    try:
        config = read_json(args.config).get("mcpServers", {})
        manifest = read_json(args.manifest)
    except McpError as error:
        print(f"copilot-mcp-audit: {error}", file=sys.stderr)
        return 2

    selected = args.servers or sorted(config)
    results = {}
    drift = False

    for name in selected:
        if name not in config:
            results[name] = {"error": "Server is not configured"}
            drift = True
            continue
        if name not in manifest:
            results[name] = {"error": "Server is absent from the tool inventory"}
            drift = True
            continue
        try:
            server_drift, result = audit_server(
                name,
                config[name],
                manifest[name],
                args.timeout,
                args.skip_live,
            )
            results[name] = result
            drift = drift or server_drift
        except (McpError, OSError) as error:
            results[name] = {"error": str(error)}
            drift = True

    if args.json_output:
        print(json.dumps(results, indent=2, sort_keys=True))
    else:
        for name in selected:
            result = results[name]
            if "error" in result:
                print(f"\n{name}\n{'-' * len(name)}\nERROR: {result['error']}")
            else:
                print_server(name, result)

    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main())
