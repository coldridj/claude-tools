#!/bin/bash
# read-once: PostCompact + SessionStart(compact) hook.
# Clears the current session's read-once cache after context compaction.
#
# Same script runs from two hook events for defence in depth:
#   - PostCompact            (primary; fires as compaction completes)
#   - SessionStart(compact)  (belt-and-suspenders; fires on the next turn
#                             after a compaction, in case PostCompact did
#                             not run)
#
# Cache lives under the per-session scratch dir, so this removes the
# whole read-once subtree for the session — including every subagent's
# cache and any diff-mode snapshots.
#
# Install: Add to .claude/settings.json under hooks.PostCompact and
# hooks.SessionStart (matcher "compact").
# See also: hook.sh (the PreToolUse hook that writes the cache).
#
# Config (env var):
#   CLAUDE_SCRATCH_ROOT   Scratch root dir (relative to $CLAUDE_PROJECT_DIR);
#                         default ".scratch". Set in .claude/settings.json.

set -euo pipefail

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SCRATCH_ROOT="$PROJECT_DIR/${CLAUDE_SCRATCH_ROOT:-.scratch}"
CACHE_DIR="$SCRATCH_ROOT/$SESSION_ID/read-once"

# Stats stay global for cross-session aggregation.
STATS_DIR="${HOME}/.claude/read-once"
STATS_FILE="$STATS_DIR/stats.jsonl"

# Count cache entries being cleared (sum lines across every *.jsonl)
CLEARED=0
if [ -d "$CACHE_DIR" ]; then
  CLEARED=$(find "$CACHE_DIR" -maxdepth 1 -name '*.jsonl' -exec wc -l {} + 2>/dev/null \
            | tail -1 | awk '{print $1}')
  CLEARED=${CLEARED:-0}
  rm -rf "$CACHE_DIR"
fi

# Same session hash format as hook.sh so stats entries line up
if command -v sha256sum >/dev/null 2>&1; then
  SESSION_HASH=$(echo -n "$SESSION_ID" | sha256sum | cut -c1-16)
else
  SESSION_HASH=$(echo -n "$SESSION_ID" | shasum -a 256 | cut -c1-16)
fi

NOW=$(date +%s)
if [ "$CLEARED" -gt 0 ] && [ -d "$STATS_DIR" ]; then
  echo "{\"ts\":${NOW},\"session\":\"${SESSION_HASH}\",\"event\":\"compact\",\"cleared\":${CLEARED}}" >> "$STATS_FILE"
fi

exit 0
