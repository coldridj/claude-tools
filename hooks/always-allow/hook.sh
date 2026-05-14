#!/bin/bash
# always-allow: PreToolUse hook — emits a `permissionDecision: allow` for Bash
# commands matching a configured regex allowlist, suppressing the prompt.
#
# Hook output format: Claude Code's PreToolUse schema requires the decision
# to live inside `hookSpecificOutput` (the top-level `{"decision":"allow"}`
# legacy form is rejected with "Hook JSON output validation failed").
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
# Multi-command guard:
#   Commands containing &&, ||, ;, or a newline are NEVER auto-allowed.
#
# Pipes (`|`) are conditionally allowed: an allowlisted base command may be
# followed by one or more pipe segments, each of which must be a "safe pipe
# filter" — a read-only stdin→stdout binary from a fixed whitelist
# (SAFE_PIPE_FILTERS) with no `>` / `>>` redirect inside the segment. This
# means `bash scripts/test.sh 2>&1 | tail -20`, `cmd | grep foo | wc -l`,
# etc. auto-allow when `cmd` is allowlisted. Filters that can write to a
# file (tee, sponge, sed -i, awk -i inplace) are deliberately excluded —
# zone enforcement on those is path-guard's job, not always-allow's.
#
# Override the safe-filter list with the env var
# ALWAYS_ALLOW_SAFE_PIPE_FILTERS=`space-separated names` (mostly a test knob).
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

# Emit the PreToolUse allow decision in Claude Code's required schema.
# Top-level `{"decision":"allow"}` is invalid for PreToolUse — that form is
# only accepted for UserPromptSubmit / PostToolUse / Stop / etc. PreToolUse
# requires the decision nested inside `hookSpecificOutput`.
emit_allow() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
}

# Never auto-allow commands that chain via &&, ||, ;, or span multiple lines.
# Pipes (|) are handled below with per-segment filter validation.
if [[ "$COMMAND" =~ (\&\&|\|\|) ]] || [[ "$COMMAND" == *";"* ]] || [[ "$COMMAND" == *$'\n'* ]]; then
  log "DENIED multi-command: $COMMAND"
  exit 0
fi

# Safe pipe filters: stdin→stdout binaries with no flag that writes a file.
# `sed` and `awk` are excluded because their -i / -i inplace flags can write
# the input file in place. `tee` and `sponge` are excluded because they
# write a named file. `cat` is excluded as a matter of read-guard policy
# (file reads go through the Read tool). Override with the
# ALWAYS_ALLOW_SAFE_PIPE_FILTERS env var for tests / consumer policy.
SAFE_PIPE_FILTERS_DEFAULT=(head tail wc tr cut sort uniq nl rev fold column jq yq grep egrep fgrep rg)
if [ -n "${ALWAYS_ALLOW_SAFE_PIPE_FILTERS:-}" ]; then
  read -ra SAFE_PIPE_FILTERS <<< "$ALWAYS_ALLOW_SAFE_PIPE_FILTERS"
else
  SAFE_PIPE_FILTERS=("${SAFE_PIPE_FILTERS_DEFAULT[@]}")
fi

is_safe_filter() {
  local seg="$1"
  # Strip leading and trailing whitespace.
  seg="${seg#"${seg%%[![:space:]]*}"}"
  seg="${seg%"${seg##*[![:space:]]}"}"
  [ -z "$seg" ] && return 1
  # Reject any redirect — could write to a file we haven't vetted.
  case "$seg" in
    *">"*) return 1 ;;
  esac
  # First token must be in the whitelist (binary name only, no path or sub).
  local first="${seg%%[[:space:]]*}"
  case "$first" in
    */*) return 1 ;;       # rejects "/bin/head" etc.
    *\$*|*\`*) return 1 ;; # rejects $VAR / `cmd` substitutions in the binary name
  esac
  local f
  for f in "${SAFE_PIPE_FILTERS[@]}"; do
    [ "$first" = "$f" ] && return 0
  done
  return 1
}

# Split the command at top-level `|` into BASE_CMD (segment 0) + filter
# segments. The earlier guard already rejected `||`, so any `|` here is a
# single pipe operator. If there is no pipe, BASE_CMD is the whole command.
BASE_CMD="$COMMAND"
if [[ "$COMMAND" == *"|"* ]]; then
  IFS='|' read -ra _SEGS <<< "$COMMAND"
  BASE_CMD="${_SEGS[0]}"
  i=1
  while [ "$i" -lt "${#_SEGS[@]}" ]; do
    if ! is_safe_filter "${_SEGS[$i]}"; then
      log "DENIED unsafe pipe filter: ${_SEGS[$i]}"
      exit 0
    fi
    i=$((i + 1))
  done
  # Trim trailing whitespace on the base so the regex matchers don't have to
  # account for `cmd  ` (multi-space) ending the segment.
  BASE_CMD="${BASE_CMD%"${BASE_CMD##*[![:space:]]}"}"
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
  if matches "$BASE_CMD" BG_ALLOWED; then
    log "ALLOWED (background) by config: $COMMAND"
    emit_allow
  else
    log "DENIED background command (no [background] match): $COMMAND"
  fi
else
  # Foreground commands: either section may auto-allow.
  if matches "$BASE_CMD" ALLOWED || matches "$BASE_CMD" BG_ALLOWED; then
    log "ALLOWED by config: $COMMAND"
    emit_allow
  fi
fi

exit 0
