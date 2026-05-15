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
#   - append a SessionStart line to today's .session-events-<date>.jsonl
#     (see "Post-mortem logging" below).
#   - GC: remove anything directly under the scratch root (top-level files or
#     per-session dirs) older than 7 days. Catches crashed sessions that
#     never reached SessionEnd, and legacy pre-per-session scratch files.
#
# SessionEnd:
#   - append a SessionEnd line to today's .session-events-<date>.jsonl.
#   - rm -rf $CLAUDE_PROJECT_DIR/$CLAUDE_SCRATCH_ROOT/<session_id>
#
# Post-mortem logging (added 2026-05-15, task #34):
#   Both events append a single-line JSON record to
#   $SCRATCH_ROOT/.session-events-<utc-date>.jsonl with ts, event,
#   session_id, path. The structural bug — `claude --resume` of the
#   same session in two terminals causing SessionEnd in one to wipe
#   the shared scratch dir — is deferred to the daemon (BUGS.md). The
#   log lets a user post-mortem the next incident: `jq -c .` on the
#   relevant date file shows the full SessionStart/SessionEnd timeline.
#   Log files sit at depth 1 under SCRATCH_ROOT so the 7-day GC sweeps
#   them naturally as they age.
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

# Best-effort post-mortem log line. Failures here never block the event;
# the structural cleanup must still happen.
log_session_event() {
  local event="$1"
  local ts day log_file
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u 2>/dev/null || echo unknown)
  day=$(date -u +%Y-%m-%d 2>/dev/null || echo unknown)
  log_file="$SCRATCH_ROOT/.session-events-$day.jsonl"
  mkdir -p "$SCRATCH_ROOT" 2>/dev/null || return 0
  printf '{"ts":"%s","event":"%s","session_id":"%s","path":"%s"}\n' \
    "$ts" "$event" "$SESSION_ID" "$SESSION_SCRATCH" \
    >> "$log_file" 2>/dev/null || true
}

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

    log_session_event SessionStart

    # GC: anything directly under the scratch root older than 7 days.
    # The touch above bumps this session's mtime, so it is never swept.
    find "$SCRATCH_ROOT" -mindepth 1 -maxdepth 1 -mtime +7 \
      -exec rm -rf {} + 2>/dev/null || true
    ;;

  SessionEnd)
    if [ -d "$SESSION_SCRATCH" ]; then
      log_session_event SessionEnd
      rm -rf "$SESSION_SCRATCH"
    fi
    ;;
esac

exit 0
