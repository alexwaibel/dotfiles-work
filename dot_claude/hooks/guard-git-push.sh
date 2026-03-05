#!/usr/bin/env bash
# Pre-tool-use hook: blocks git push to any branch not matching alwaibel/claude/*
# Receives JSON on stdin: { "tool_name": "Bash", "tool_input": { "command": "..." } }
# No jq dependency — uses only bash builtins and sed.

set -euo pipefail

INPUT=$(cat)

# Only inspect Bash calls — extract tool_name with sed
TOOL=$(echo "$INPUT" | sed -n 's/.*"tool_name" *: *"\([^"]*\)".*/\1/p')
[[ "$TOOL" == "Bash" ]] || exit 0

# Extract the command value — handle escaped quotes within the JSON string
# Extract command value: match the inner string, stripping outer JSON structure
CMD=$(echo "$INPUT" | sed -n 's/.*"command" *: *"\(.*\)".*/\1/p' | sed 's/\\"/"/g; s/[[:space:]]*}[[:space:]]*}[[:space:]]*$//')

# Only inspect commands that contain "git push"
[[ "$CMD" == *"git push"* ]] || exit 0

# --- Block command chaining / subshells ---
if echo "$CMD" | grep -qE '&&|\|\||[;|]|`|\$\('; then
  echo "BLOCK: Command chaining is not allowed with git push. Use a single git push command." >&2
  exit 2
fi

# --- Extract the git push portion ---
PUSH_CMD="${CMD#*git push}"

# Tokenize, skipping flags (anything starting with -)
ARGS=()
for token in $PUSH_CMD; do
  [[ "$token" == -* ]] && continue
  ARGS+=("$token")
done

# ARGS[0] = remote, ARGS[1..n] = refspecs/branches

# Block bare push with no explicit branch
if [[ ${#ARGS[@]} -lt 2 ]]; then
  echo "BLOCK: Bare 'git push' without an explicit branch is not allowed. Specify the branch, e.g. git push origin alwaibel/claude/<id>-<slug>" >&2
  exit 2
fi

ALLOWED_PREFIX="alwaibel/claude/"

# Check each refspec argument (everything after the remote)
for ((i=1; i<${#ARGS[@]}; i++)); do
  ref="${ARGS[$i]}"

  # Handle refspec syntax local:remote — validate the DESTINATION (after :)
  if [[ "$ref" == *:* ]]; then
    dest="${ref#*:}"
    if [[ "$dest" != "${ALLOWED_PREFIX}"* ]]; then
      echo "BLOCK: Refspec destination '$dest' is not under '${ALLOWED_PREFIX}*'. Pushes are only allowed to alwaibel/claude/* branches." >&2
      exit 2
    fi
  else
    # Plain branch name
    if [[ "$ref" != "${ALLOWED_PREFIX}"* ]]; then
      echo "BLOCK: Branch '$ref' is not under '${ALLOWED_PREFIX}*'. Pushes are only allowed to alwaibel/claude/* branches." >&2
      exit 2
    fi
  fi
done

exit 0
