#!/bin/bash
# always-allow: PreToolUse hook — emits {"decision": "allow"} for Bash commands
# matching a configured regex allowlist, suppressing the permission prompt.
#
# Config files (concatenated, in load order):
#   1. .claude/hooks/always-allow/default.always-allow  (shipped with the hook)
#   2. $HOME/.claude/.always-allow                      (user defaults)
#   3. $CLAUDE_PROJECT_DIR/.always-allow                (project rules)
#
# Each file is a flat list of POSIX ERE patterns, one per line. A command is
# auto-allowed if it matches any entry. Comments begin with # and run to end
# of line. Multi-command lines (containing &&, ||, ;, |, or newlines) and
# background commands are never auto-allowed.
#
# Disabled by setting ALWAYS_ALLOW_DISABLED=1.

set -euo pipefail

if [ "${ALWAYS_ALLOW_DISABLED:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only check Bash commands
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [ -z "$COMMAND" ]; then
  exit 0
fi

log() {
  if [ "${ALWAYS_ALLOW_LOG:-0}" = "1" ]; then
    echo "[always-allow] $*" >&2
  fi
}

# Never auto-allow commands that chain multiple operations or span multiple lines
if [[ "$COMMAND" =~ (&&|\|\||[;|]) ]] || [[ "$COMMAND" == *$'\n'* ]]; then
  log "DENIED multi-command: $COMMAND"
  exit 0
fi

# Never auto-allow background commands — they may hide chained payloads in scripts
RUN_IN_BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // false')
if [ "$RUN_IN_BG" = "true" ]; then
  log "DENIED background command: $COMMAND"
  exit 0
fi

# ============================================================================
# Config loader
# ============================================================================

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
HOOK_DIR="${ALWAYS_ALLOW_HOOK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

ALLOWED=()

load_config() {
  local file="$1" raw entry
  [ -f "$file" ] || return 0
  while IFS= read -r raw || [ -n "$raw" ]; do
    entry="${raw%%#*}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ -z "$entry" ] && continue
    log "allowing $entry"
    ALLOWED+=("$entry")
  done < "$file"
}

load_config "$HOOK_DIR/default.always-allow"
load_config "$HOME/.claude/.always-allow"
load_config "$PROJECT_DIR/.always-allow"

# Check if an operation is allowed via config
is_allowed() {
  local op="$1"
  for a in "${ALLOWED[@]+"${ALLOWED[@]}"}"; do
    if [[ $op =~ $a ]]; then
      log "ALLOWED by config: $op"
      return 0
    fi
  done
  return 1
}

if is_allowed "$COMMAND"; then
	printf '%s\n' '{"decision": "allow"}' >&1
fi

exit 0;
