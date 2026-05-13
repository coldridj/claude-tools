#!/bin/bash
# always-allow: PreToolUse hook — emits {"decision": "allow"} for Bash commands
# matching a configured regex allowlist, suppressing the permission prompt.
#
# Config files (concatenated, in load order):
#   1. .claude/hooks/always-allow/default.always-allow  (shipped with the hook)
#   2. $HOME/.claude/.always-allow                      (user defaults)
#   3. $CLAUDE_PROJECT_DIR/.always-allow                (project rules)
#
# Each file is a list of POSIX ERE patterns, one per line, grouped into named
# sections. Two sections are recognised:
#   [allow]      — auto-allow foreground single-command invocations only.
#                  This is the default section for unlabeled lines, so existing
#                  flat-list configs keep working unchanged.
#   [background] — auto-allow both foreground AND background single commands.
#                  Use sparingly: background invocations can hide chained
#                  payloads inside scripts. Reserve this for trusted, well-
#                  known launchers (dev servers, watchers, file daemons).
#
# Multi-command lines (containing &&, ||, ;, |, or newlines) are NEVER auto-
# allowed regardless of section.
#
# Comments begin with # and run to end of line.
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

RUN_IN_BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // false')

# ============================================================================
# Config loader
# ============================================================================

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
HOOK_DIR="${ALWAYS_ALLOW_HOOK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

ALLOWED=()
BG_ALLOWED=()

load_config() {
  local file="$1" raw entry section="allow"
  [ -f "$file" ] || return 0
  while IFS= read -r raw || [ -n "$raw" ]; do
    entry="${raw%%#*}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ -z "$entry" ] && continue
    if [[ "$entry" =~ ^\[([a-z]+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    case "$section" in
      allow)
        log "allowing $entry"
        ALLOWED+=("$entry")
        ;;
      background|bg)
        log "background-allowing $entry"
        BG_ALLOWED+=("$entry")
        ;;
      *)
        log "unknown section [$section] — skipping pattern $entry"
        ;;
    esac
  done < "$file"
}

load_config "$HOOK_DIR/default.always-allow"
load_config "$HOME/.claude/.always-allow"
load_config "$PROJECT_DIR/.always-allow"

# Check if $1 matches any pattern in the array named by $2.
matches() {
  local op="$1" arr_name="$2"
  local -n arr="$arr_name"
  local pat
  for pat in "${arr[@]+"${arr[@]}"}"; do
    if [[ $op =~ $pat ]]; then
      return 0
    fi
  done
  return 1
}

if [ "$RUN_IN_BG" = "true" ]; then
  # Background commands: only [background] patterns may auto-allow.
  if matches "$COMMAND" BG_ALLOWED; then
    log "ALLOWED (background) by config: $COMMAND"
    printf '%s\n' '{"decision": "allow"}'
  else
    log "DENIED background command (no [background] match): $COMMAND"
  fi
else
  # Foreground commands: either section may auto-allow.
  if matches "$COMMAND" ALLOWED || matches "$COMMAND" BG_ALLOWED; then
    log "ALLOWED by config: $COMMAND"
    printf '%s\n' '{"decision": "allow"}'
  fi
fi

exit 0
