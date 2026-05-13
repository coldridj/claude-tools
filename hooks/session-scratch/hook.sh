#!/bin/bash
# session-scratch: SessionStart + SessionEnd dispatcher.
#
# Gives every Claude Code session its own scratch subdirectory so that
# concurrent sessions in the same project never collide on scratch writes.
#
# SessionStart:
#   - mkdir -p $CLAUDE_PROJECT_DIR/$CLAUDE_SCRATCH_ROOT/<session_id>
#   - touch the dir so its mtime is "now" (mkdir -p is a no-op on an
#     existing dir and would not refresh mtime — without the touch, a
#     `--resume` of a session older than 7 days would have its scratch
#     swept by the GC step below).
#   - export CLAUDE_SESSION_ID and CLAUDE_SESSION_SCRATCH via $CLAUDE_ENV_FILE
#     so subsequent Bash tool invocations see them
#   - GC: remove anything directly under the scratch root (top-level files or
#     per-session dirs) older than 7 days. Catches crashed sessions that
#     never reached SessionEnd, and legacy pre-per-session scratch files.
#
# SessionEnd:
#   - rm -rf $CLAUDE_PROJECT_DIR/$CLAUDE_SCRATCH_ROOT/<session_id>
#
# Config (env var):
#   CLAUDE_SCRATCH_ROOT   Directory name (relative to $CLAUDE_PROJECT_DIR) for
#                         the scratch root. Default: ".scratch". Set in
#                         .claude/settings.json so every hook subprocess sees
#                         the same value.
#
# Install: register for both SessionStart and SessionEnd in settings.json.
# This single dispatcher script handles both via .hook_event_name.

set -euo pipefail

INPUT=$(cat)

EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$SESSION_ID" ] || [ -z "$EVENT" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SCRATCH_ROOT="$PROJECT_DIR/${CLAUDE_SCRATCH_ROOT:-.scratch}"
SESSION_SCRATCH="$SCRATCH_ROOT/$SESSION_ID"

case "$EVENT" in
  SessionStart)
    mkdir -p "$SESSION_SCRATCH"
    # Bump mtime so the 7-day GC below cannot sweep this dir on resume.
    # `mkdir -p` is a no-op on an existing dir and does NOT update the
    # mtime — without the explicit touch, a `--resume` of a session
    # whose dir is >7 days old would have its scratch nuked by the
    # find -mtime +7 below.
    touch "$SESSION_SCRATCH"

    if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
      {
        echo "export CLAUDE_SESSION_ID=\"$SESSION_ID\""
        echo "export CLAUDE_SESSION_SCRATCH=\"$SESSION_SCRATCH\""
      } >> "$CLAUDE_ENV_FILE"
    fi

    # GC: anything directly under the scratch root older than 7 days.
    # The touch above bumps this session's mtime, so it is never swept.
    find "$SCRATCH_ROOT" -mindepth 1 -maxdepth 1 -mtime +7 \
      -exec rm -rf {} + 2>/dev/null || true
    ;;

  SessionEnd)
    if [ -d "$SESSION_SCRATCH" ]; then
      rm -rf "$SESSION_SCRATCH"
    fi
    ;;
esac

exit 0
