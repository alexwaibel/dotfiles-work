#!/usr/bin/env bash
# Copilot CLI preToolUse hook: keeps globally approved rg, sort, and find
# invocations read-only and prevents them from composing arbitrary shell code.
#
# This is a guardrail for direct commands, not a general shell parser. sed and
# awk remain unapproved because their embedded languages can execute commands
# and write files in ways that cannot be safely filtered with argument checks.

set -uo pipefail

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(echo "$INPUT" | jq -r '.toolName // empty' | tr '[:upper:]' '[:lower:]')
[[ "$TOOL" == "bash" || "$TOOL" == "shell" ]] || exit 0

CMD=$(echo "$INPUT" | jq -r '
  (.toolArgs // "") as $raw
  | (try ($raw | fromjson) catch {}) as $obj
  | ($obj.command // $obj.script // $obj.cmd // "")
')
[[ -n "$CMD" ]] || exit 0

deny() {
  local reason="$1"
  jq -nc --arg r "$reason" '{permissionDecision:"deny", permissionDecisionReason:$r}'
  exit 0
}

TRIMMED="${CMD#"${CMD%%[![:space:]]*}"}"
if [[ "$TRIMMED" == command\ * ]]; then
  TRIMMED="${TRIMMED#command }"
fi

FIRST="${TRIMMED%%[[:space:]]*}"
FIRST="${FIRST##*/}"

case "$FIRST" in
  rg|sort|find) ;;
  *) exit 0 ;;
esac

# Keep the approved command as one direct process. Pipelines, redirections,
# command substitutions, and chaining can turn a read command into execution
# or file mutation through another command.
if [[ "$CMD" == *$'\n'* ]] || echo "$CMD" | grep -qE '&&|\|\||[;|<>]|`|\$\('; then
  deny "${FIRST} must run as a single command without chaining, pipes, redirection, or command substitution."
fi

case "$FIRST" in
  rg)
    if ! echo "$CMD" | grep -qE '(^|[[:space:]])rg[[:space:]]+--no-config([[:space:]]|$)|(^|[[:space:]])/[^[:space:]]*/rg[[:space:]]+--no-config([[:space:]]|$)'; then
      deny "rg must include --no-config so user or environment configuration cannot enable a preprocessor."
    fi
    if echo "$CMD" | grep -qE '(^|[[:space:]])--pre([=[:space:]]|$)|(^|[[:space:]])--pre-glob([=[:space:]]|$)'; then
      deny "rg --pre and --pre-glob are not allowed because preprocessors execute external commands."
    fi
    ;;
  sort)
    if echo "$CMD" | grep -qE '(^|[[:space:]])-o([^[:space:]]*|[[:space:]]+)|(^|[[:space:]])--output([=[:space:]]|$)|(^|[[:space:]])--compress-program([=[:space:]]|$)'; then
      deny "sort output files and external compression programs are not allowed."
    fi
    ;;
  find)
    if echo "$CMD" | grep -qE '(^|[[:space:]])-(delete|exec|execdir|ok|okdir|fls|fprint|fprint0|fprintf)([[:space:]]|$)'; then
      deny "find actions that delete, execute commands, or write files are not allowed."
    fi
    ;;
esac

exit 0
