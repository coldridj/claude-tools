#!/bin/bash
# scratch-allow: PreToolUse hook — auto-approves Write / Edit / MultiEdit
# calls whose target lies inside the per-session scratch directory.
#
# path-guard already permits writes inside `$CLAUDE_SESSION_SCRATCH` (it
# is inside the allowed project zone), but Claude Code's harness still
# prompts the user for each new file. This hook short-circuits those
# prompts so the scratch+mv workflow doesn't require a click per file.
#
# Decision contract:
#   - Tool ∈ {Write, Edit, MultiEdit}: if `tool_input.file_path` resolves
#     to a path under `$CLAUDE_SESSION_SCRATCH`, emit
#     `permissionDecision: allow`. Otherwise pass through silently.
#   - Any other tool: pass through silently. Other hooks decide.
#   - jq missing: fail-open with a warning (same convention as
#     always-allow). Path-guard remains the security backstop.
#
# Disabled by setting SCRATCH_ALLOW_DISABLED=1.

set -euo pipefail

if [ "${SCRATCH_ALLOW_DISABLED:-0}" = "1" ]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[scratch-allow] jq not found in PATH — fail-open, no auto-allow this call" >&2
  exit 0
fi

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE_PATH" ] && exit 0

# Require an explicit scratch root from the env. If unset, we can't
# determine the per-session boundary and must pass through.
SCRATCH="${CLAUDE_SESSION_SCRATCH:-}"
[ -z "$SCRATCH" ] && exit 0

# Canonicalise both sides so `..` / symlinks don't bypass the prefix check.
SCRATCH_ABS=$(realpath -m "$SCRATCH" 2>/dev/null || printf '%s' "$SCRATCH")
[ -z "$SCRATCH_ABS" ] && exit 0

# Resolve relative file_path against CLAUDE_PROJECT_DIR (the project
# zone), matching path-guard's normalisation.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
case "$FILE_PATH" in
  /*) ;;
  ~)    FILE_PATH="$HOME" ;;
  ~/*)  FILE_PATH="$HOME/${FILE_PATH#\~/}" ;;
  *)    FILE_PATH="$PROJECT_DIR/$FILE_PATH" ;;
esac
FILE_ABS=$(realpath -m "$FILE_PATH" 2>/dev/null || printf '%s' "$FILE_PATH")
[ -z "$FILE_ABS" ] && exit 0

# Prefix match: file must be strictly inside the scratch root. Append
# trailing slashes so `<scratch>` and `<scratch-sibling>/foo` don't both
# match `<scratch>` as a prefix.
case "$FILE_ABS/" in
  "$SCRATCH_ABS/"*)
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
    ;;
esac

exit 0
