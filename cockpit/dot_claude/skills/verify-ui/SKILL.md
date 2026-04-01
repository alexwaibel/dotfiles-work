---
name: verify-ui
description: Visually verify UI changes by launching a dev server, navigating with a headless browser, and taking screenshots. Use after making UI/styling changes to confirm they look correct before pushing. Works with any repo that has a dev server.
argument-hint: "[url-or-path]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - mcp__playwright__browser_navigate
  - mcp__playwright__browser_take_screenshot
  - mcp__playwright__browser_snapshot
  - mcp__playwright__browser_tab_list
  - mcp__playwright__browser_close
---

# Verify UI

Visually verify UI changes using a headless browser.

## Arguments

`$ARGUMENTS` — optional URL or path to verify (e.g. `http://localhost:3000/agentEditor` or `/agentEditor`). If a relative path is given, prepend the dev server base URL. If omitted, ask the user what to check.

## Procedure

### Step 1: Discover repo browser test setup

Read the repo's CLAUDE.md and follow links to testing docs. Look for:
- Dev server command and port (e.g. `yarn staging` on a specific port)
- Standalone / mock mode URL patterns (query params that bypass auth or stub a host)
- Playwright config files (`playwright.config.*`) for viewport sizes, base URL, web server config
- Existing e2e mock services or fixture data

If CLAUDE.md doesn't link to relevant docs, fall back to:
- Check `package.json` for `dev`, `start`, `staging`, `e2e` scripts
- Look for `playwright.config.*`, `e2e/`, `tests/` directories
- Search for test host patterns (mock auth, standalone mode, storage state)

### Step 2: Ensure a dev server is running

Check for a running process on expected ports via `ss -tlnp`.

If no server is running:
- Use the dev server command discovered in Step 1
- Start it in the background via Bash (run_in_background)
- Wait a few seconds, then verify the port is listening

### Step 3: Build the target URL

Combine the dev server base URL + the target path from `$ARGUMENTS`.

If the repo has a standalone/mock mode (discovered in Step 1), append the required query params so the page loads without auth or host dependencies.

### Step 4: Navigate and screenshot

1. Navigate using `mcp__playwright__browser_navigate`
2. Take a screenshot using `mcp__playwright__browser_take_screenshot` (use `fullPage: true` if the page scrolls)
3. Review the image

### Step 5: Evaluate

Compare what you see against:
- The changes you just made (do they appear correct?)
- The user's request (does it match what was asked for?)
- General UI quality (alignment, spacing, overflow, truncation)

### Step 6: Report

- If it looks good: confirm with the screenshot
- If there are issues: describe what's wrong and offer to fix

### Step 7: Debug (if needed)

If something looks off, use `mcp__playwright__browser_snapshot` to get the accessibility tree, or inspect computed styles to diagnose layout issues.

## Notes

- This skill is repo-agnostic. The repo's docs are the source of truth for how to run and access the app.
- The browser runs headless — no display needed.
- Screenshots are the primary verification method. Use snapshots for debugging.
- If the repo has no documented standalone mode and requires auth, ask the user for guidance.
- Clean up: close the browser tab when done. Leave the dev server running for the user.
