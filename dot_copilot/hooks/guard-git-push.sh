#!/usr/bin/env bash
# Copilot CLI preToolUse hook: blocks `git push` to any branch outside
# alwaibel/claude/*.
#
# Stdin schema (Copilot CLI):
#   {"timestamp": <ms>, "cwd": "...", "toolName": "bash", "toolArgs": "<json-string>"}
# toolArgs is itself a JSON string; for bash it typically contains a "command"
# or "script" field. We try both.
#
# Decision is emitted to stdout as JSON:
#   {"permissionDecision": "deny", "permissionDecisionReason": "..."}
# Exiting 0 with no output = pass through to normal approval flow.

set -uo pipefail

INPUT=$(cat)

# Need jq to parse — fall through if missing rather than blocking everything
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(echo "$INPUT" | jq -r '.toolName // empty' | tr '[:upper:]' '[:lower:]')
[[ "$TOOL" == "bash" || "$TOOL" == "shell" ]] || exit 0

# toolArgs is a JSON-encoded string. Unwrap to an object, then pull command/script.
CMD=$(echo "$INPUT" | jq -r '
  (.toolArgs // "") as $raw
  | (try ($raw | fromjson) catch {}) as $obj
  | ($obj.command // $obj.script // $obj.cmd // "")
')
[[ -n "$CMD" ]] || exit 0

# Only inspect commands that actually contain "git push"
[[ "$CMD" == *"git push"* ]] || exit 0

deny() {
  local reason="$1"
  jq -nc --arg r "$reason" '{permissionDecision:"deny", permissionDecisionReason:$r}'
  exit 0
}

# Block command chaining / subshells around git push — too easy to slip past
if echo "$CMD" | grep -qE '&&|\|\||[;|]|`|\$\('; then
  deny "Command chaining is not allowed with git push. Use a single git push command."
fi

PUSH_CMD="${CMD#*git push}"

ARGS=()
for token in $PUSH_CMD; do
  [[ "$token" == -* ]] && continue
  ARGS+=("$token")
done

if [[ ${#ARGS[@]} -lt 2 ]]; then
  deny "Bare 'git push' without an explicit branch is not allowed. Specify the branch, e.g. git push origin alwaibel/claude/<id>-<slug>"
fi

ALLOWED_PREFIX="alwaibel/claude/"

for ((i=1; i<${#ARGS[@]}; i++)); do
  ref="${ARGS[$i]}"

  if [[ "$ref" == *:* ]]; then
    dest="${ref#*:}"
    if [[ "$dest" != "${ALLOWED_PREFIX}"* ]]; then
      deny "Refspec destination '$dest' is not under '${ALLOWED_PREFIX}*'. Pushes are only allowed to alwaibel/claude/* branches."
    fi
  else
    if [[ "$ref" != "${ALLOWED_PREFIX}"* ]]; then
      deny "Branch '$ref' is not under '${ALLOWED_PREFIX}*'. Pushes are only allowed to alwaibel/claude/* branches."
    fi
  fi
done

exit 0
