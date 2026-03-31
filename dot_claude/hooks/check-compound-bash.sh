#!/usr/bin/env bash
# PreToolUse hook: splits compound Bash commands (&&, ||, ;) and checks
# each part against the allow list in settings.json. If every part matches
# an allow pattern, returns permissionDecision "allow". Otherwise exits
# silently to let normal permission handling decide.
#
# Requires jq for JSON parsing (settings + stdin).
# Conservative: if parsing is ambiguous or jq is missing, falls through to ask.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -n "$CMD" ]] || exit 0

# Only intervene for compound commands
echo "$CMD" | grep -qE '&&|\|\||;' || exit 0

# Bail on subshells/backticks — too complex to split safely
if echo "$CMD" | grep -qE '`|\$\('; then
  exit 0
fi

# --- Load allow patterns from settings ---
SETTINGS="$HOME/.claude/settings.json"
[[ -f "$SETTINGS" ]] || exit 0

# Extract Bash(...) prefixes from the allow list.
# "Bash(git status:*)" → "git status"
# "Bash(cd /home/user/repo:*)" → "cd /home/user/repo"
mapfile -t PREFIXES < <(
  jq -r '.permissions.allow[]? // empty
    | select(startswith("Bash("))
    | sub("^Bash\\("; "")
    | sub(":?\\*?\\)$"; "")' "$SETTINGS"
)

if [[ ${#PREFIXES[@]} -eq 0 ]]; then
  exit 0
fi

# --- Split compound command into parts ---
# Replace || first (before splitting on |), then && and ;
# Use ASCII Unit Separator (0x1f) as delimiter to avoid collision with command content
DELIM=$'\x1f'
SPLIT=$(echo "$CMD" | sed "s/||/${DELIM}/g; s/&&/${DELIM}/g; s/;/${DELIM}/g")

while IFS= read -r part; do
  # Trim leading/trailing whitespace
  part=$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$part" ]] && continue

  # Expand ~ to $HOME so it matches absolute-path allow patterns
  part="${part// \~\// $HOME/}"
  part="${part/#\~\//$HOME/}"

  matched=false
  for prefix in "${PREFIXES[@]}"; do
    if [[ "$part" == "$prefix"* ]]; then
      matched=true
      break
    fi
  done

  if [[ "$matched" == false ]]; then
    # Unrecognized part — fall through to normal permission handling
    exit 0
  fi
done <<< "${SPLIT//$DELIM/$'\n'}"

# All parts matched allow patterns
cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"All parts of compound command individually match allow list"}}
EOF
