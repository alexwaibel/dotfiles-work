---
name: capture-idea
description: Capture a new idea as its own org-roam node (proper :ID:, title, slug, DB-registered) linked to the central Ideas hub, with the idea body written by AI in org-mode. Also lists ideas and promotes one to an ADO work item only when you start it. Use when the user says "capture idea", "new idea", "/idea", "add to idea backlog", "list ideas", "/ideas", or "promote idea".
allowed-tools: shell
---

# Capture Idea

Separate **capturing** ideas (free, into notes) from **committing** them (an ADO work
item only when you actually start). The ADO board stays limited to active work; the idea
backlog lives in org-roam and is picked up opportunistically.

Each idea is its **own org-roam node** (a page), linked to the central **Ideas** hub node.
The hub's backlinks are the living backlog — nothing to hand-curate.

## Config

- Notes graph: `/mnt/c/Users/alwaibel/OneDrive - Microsoft/Documents/Logseq` (org-roam via Doom; Logseq dir layout).
- Ideas hub node org-id: `9344e215-75d9-4dc7-8b67-600b5909b55b` (`pages/Ideas.org`).
- Emacs helper: `capture-idea.el` in this skill dir (loaded via emacsclient).
- Emacs owns node creation; the AI only authors the idea body.

## Division of labour (important)

- **Emacs/org-roam** create the node: `:ID:`, `#+title`, slug filename, DB registration,
  the `#ai` filetag, `:CAPTURED_BY:/:CAPTURED_AT:` cleanup markers, and the backlink to
  the Ideas hub. Do NOT hand-write these.
- **The AI** writes only the idea **body**, as **org-mode**, into a temp file.
- Never route body text through org-capture templates — template `%`-escapes corrupt
  ordinary content (e.g. `24%`, `%t`). The helper inserts the body verbatim; rely on it.

## AI markers (for later cleanup)

Every node the helper creates carries, automatically:
- `#+filetags: :ai:` on the node, and
- `:CAPTURED_BY: copilot-cli` + `:CAPTURED_AT: [timestamp]` file-level properties.
Find all AI-created ideas later with e.g. `grep -rl 'CAPTURED_BY: copilot-cli' <graph>/pages`.

## Capture procedure

1. Confirm the graph path is reachable; if not, tell the user (don't write elsewhere).
2. Gather from the user (ask only for what's missing): a short **title**; **effort**
   (`#effort/s|m|l`); one or more **area** tags (reuse existing flat vocab — `#perf`,
   `#security`, `#accessibility`, `#approvals`, `#dx`, …); a **repo** tag `#repo/<name>`
   inferred from the current working directory when invoked inside a repo.
3. **Author the idea body as org-mode** in a temp file (e.g. `/tmp/idea-body.org`). Put the
   tags on the first body line so they're visible and greppable, then a short rationale and a
   concrete first step. If a longer artifact exists (e.g. a proposal doc), either convert it
   to org in the body or copy the file into `<graph>/assets/` and reference it with a
   `[[file:../assets/<name>]]` link so the node stays self-contained.
4. Create the node deterministically via the helper:
   ```bash
   emacsclient --alternate-editor="" --eval \
     "(progn (load \"$HOME/.copilot/skills/capture-idea/capture-idea.el\") \
        (awb/capture-idea \"<TITLE>\" \"/tmp/idea-body.org\" \
          \"9344e215-75d9-4dc7-8b67-600b5909b55b\"))"
   ```
   The helper returns the new node's file path and registers the hub backlink.
5. Confirm to the user: node path, that it's linked under the Ideas hub, and that it's in the
   backlog — not on the ADO board. Delete the temp body file.

## List procedure (`/ideas`)

Prefer org-roam's own view — the Ideas hub's backlinks buffer (`SPC n r b` on the hub) is the
canonical list. For a filtered CLI view, grep `<graph>/pages` for `:ai:`/`#idea` nodes and
parse title + `#effort/*` + area + `#repo/*`; offer common filters ("small ideas" = `#effort/s`,
by area, by current repo). Do not modify anything on a list.

## Promote procedure (`promote idea`)

Only when the user is about to start an idea:
1. Confirm the target node by title.
2. Create an ADO work item per the cockpit conventions (`~/.copilot/copilot-instructions.md`;
   see `/work`, `/standup`) — carry over title, rationale, first step, and any doc link.
3. In the node, record `- Promoted to [[ADO <id>]] <date>` and add a `#promoted` filetag so it
   drops out of the active backlog (keep the node for provenance). Re-run
   `org-roam-db-update-file` if edited outside Emacs.
4. Report the ADO id. Optionally suggest capping in-flight promotions (e.g. ≤2).
