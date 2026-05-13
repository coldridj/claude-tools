#!/bin/bash
# read-once: combined PreToolUse / PostCompact / SessionStart(compact) hook.
#
# Dispatches on hook_event_name from the input JSON:
#   - PreToolUse + tool_name=Read  → track reads; suppress redundant re-reads
#                                    of unchanged files. Optional diff mode.
#   - PostCompact                  → clear this session's read-once cache
#                                    (compaction means prior context is gone).
#   - SessionStart                 → same cache clear, as a belt-and-suspenders
#                                    fallback if PostCompact did not fire.
#                                    settings.json should route only the
#                                    matcher=compact variant here.
#
# Invalidation model is *deterministic* — driven by lifecycle hooks, not
# wall-clock TTL:
#   - PostCompact (this file):              clears cache on /compact.
#   - SessionStart matcher=compact (same):  belt-and-suspenders.
#   - /clear, --resume:                     new session_id ⇒ new cache dir
#                                           under $CLAUDE_SCRATCH_ROOT/<sid>/...
#                                           Old dir cleared by session-scratch
#                                           SessionEnd (or 7d GC).
#   - File modification (mtime check):      external edits naturally bypass.
#
# Subagent isolation: subagents share the parent's session_id, but the
# hook payload exposes an `agent_id` that is unique per subagent. The
# cache file path includes that id, so a subagent never sees a "this file
# is already in context" hit from the parent's reads. agent_id absent =>
# main agent.
#
# A failsafe TTL is available but defaults to off (READ_ONCE_TTL=0). Set
# READ_ONCE_TTL to a positive value (seconds) to additionally expire
# entries after that age — useful only as a safety net for environments
# where PostCompact may not fire reliably.
#
# Diff mode: When a file HAS changed since the last read, instead of
# allowing a full re-read, show only what changed (the diff). Saves
# 80–95% of tokens when iterating. Enable with READ_ONCE_DIFF=1.
#
# Storage layout:
#   $CLAUDE_PROJECT_DIR/$CLAUDE_SCRATCH_ROOT/<session_id>/read-once/<agent>.jsonl
#   $CLAUDE_PROJECT_DIR/$CLAUDE_SCRATCH_ROOT/<session_id>/read-once/snapshots/<hash>
#   ~/.claude/read-once/stats.jsonl   (cross-session aggregation only)
#
# Install: wire each event in .claude/settings.json to this same script.
# Savings: ~2000+ tokens per prevented re-read.
#
# Config (env vars, PreToolUse path only):
#   READ_ONCE_MODE=warn     "warn" (default) allows read with advisory,
#                           "deny" blocks it. warn mode prevents Edit
#                           deadlock and parallel read cascade failures.
#   READ_ONCE_TTL=0         Failsafe TTL in seconds. 0 (default) =
#                           deterministic-only (hook-driven invalidation).
#   READ_ONCE_DIFF=1        Show only diff when files change (default: 0).
#   READ_ONCE_DIFF_MAX=40   Max diff lines before falling back to full
#                           re-read (default: 40).
#   READ_ONCE_DISABLED=1    Disable the hook entirely (PreToolUse path
#                           only; cache-clear paths still run).
#   CLAUDE_SCRATCH_ROOT     Scratch root dir (relative to $CLAUDE_PROJECT_DIR);
#                           default ".scratch". Set in .claude/settings.json.

set -euo pipefail

INPUT=$(cat)
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SCRATCH_ROOT="$PROJECT_DIR/${CLAUDE_SCRATCH_ROOT:-.scratch}"
CACHE_DIR="$SCRATCH_ROOT/$SESSION_ID/read-once"
STATS_DIR="${HOME}/.claude/read-once"
STATS_FILE="$STATS_DIR/stats.jsonl"

# Session hash kept stable so stats stay comparable to the pre-merge format.
if command -v sha256sum >/dev/null 2>&1; then
  SESSION_HASH=$(echo -n "$SESSION_ID" | sha256sum | cut -c1-16)
else
  SESSION_HASH=$(echo -n "$SESSION_ID" | shasum -a 256 | cut -c1-16)
fi

NOW=$(date +%s)

# ============================================================================
# Cache-clear path: PostCompact and SessionStart(matcher=compact).
# ============================================================================

case "$HOOK_EVENT" in
  PostCompact|SessionStart)
    CLEARED=0
    if [ -d "$CACHE_DIR" ]; then
      CLEARED=$(find "$CACHE_DIR" -maxdepth 1 -name '*.jsonl' -exec wc -l {} + 2>/dev/null \
                | tail -1 | awk '{print $1}')
      CLEARED=${CLEARED:-0}
      rm -rf "$CACHE_DIR"
    fi
    if [ "$CLEARED" -gt 0 ] && [ -d "$STATS_DIR" ]; then
      echo "{\"ts\":${NOW},\"session\":\"${SESSION_HASH}\",\"event\":\"compact\",\"cleared\":${CLEARED}}" >> "$STATS_FILE"
    fi
    exit 0
    ;;
  PreToolUse) ;;
  *) exit 0 ;;
esac

# ============================================================================
# PreToolUse path: read-once for Read tool.
# ============================================================================

if [ "${READ_ONCE_DISABLED:-0}" = "1" ]; then
  exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
if [ "$TOOL_NAME" != "Read" ]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // empty')
LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // empty')

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Partial reads (offset/limit) are never cached — user is exploring
# a large file piece by piece, each chunk is different content.
if [ -n "$OFFSET" ] || [ -n "$LIMIT" ]; then
  exit 0
fi

mkdir -p "$CACHE_DIR"
mkdir -p "$STATS_DIR"

# Mode: "warn" (default) allows read with advisory message, "deny" blocks it.
# warn mode fixes: Edit tool deadlock, parallel read cascade failures.
MODE="${READ_ONCE_MODE:-warn}"

# Diff mode config
DIFF_MODE="${READ_ONCE_DIFF:-0}"
DIFF_MAX="${READ_ONCE_DIFF_MAX:-40}"

# Snapshot directory for diff mode
if [ "$DIFF_MODE" = "1" ]; then
  SNAP_DIR="${CACHE_DIR}/snapshots"
  mkdir -p "$SNAP_DIR"
fi

# TTL: failsafe expiry. 0 (default) means no time-based expiry — rely
# entirely on PostCompact / SessionStart(compact) / session_id rotation
# to invalidate the cache. Set to a positive integer (seconds) only as
# a backup for environments where PostCompact may not fire.
TTL="${READ_ONCE_TTL:-0}"

# Agent key — distinguishes main agent from each subagent. Subagents
# share the parent's session_id but have distinct .agent_id values.
# Sanitise for filename use (uuid chars are safe; this is belt-and-braces).
AGENT_KEY_RAW="${AGENT_ID:-main}"
AGENT_KEY=$(printf '%s' "$AGENT_KEY_RAW" | tr -cd 'a-zA-Z0-9._-')
[ -z "$AGENT_KEY" ] && AGENT_KEY="main"

CACHE_FILE="${CACHE_DIR}/${AGENT_KEY}.jsonl"

# Snapshot path for this file (used in diff mode) — per-agent so a
# subagent's diff baseline does not collide with the parent's.
if [ "$DIFF_MODE" = "1" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    PATH_HASH=$(echo -n "$FILE_PATH" | sha256sum | cut -c1-16)
  else
    PATH_HASH=$(echo -n "$FILE_PATH" | shasum -a 256 | cut -c1-16)
  fi
  SNAP_FILE="${SNAP_DIR}/${AGENT_KEY}-${PATH_HASH}"
fi

# Get current file mtime (portable macOS/Linux)
if [ ! -f "$FILE_PATH" ]; then
  # File doesn't exist — let Read handle the error
  exit 0
fi

if [[ "$OSTYPE" == "darwin"* ]]; then
  CURRENT_MTIME=$(stat -f '%m' "$FILE_PATH" 2>/dev/null || echo "")
else
  CURRENT_MTIME=$(stat -c '%Y' "$FILE_PATH" 2>/dev/null || echo "")
fi

if [ -z "$CURRENT_MTIME" ]; then
  exit 0
fi

# Get file size for token estimation (~4 chars per token, line numbers add ~70%)
FILE_SIZE=$(wc -c < "$FILE_PATH" 2>/dev/null | tr -d ' ')
ESTIMATED_TOKENS=$(( (FILE_SIZE / 4) * 170 / 100 ))

# Check if we've seen this file before for this (session, agent) pair
CACHED_MTIME=""
CACHED_TS=""
if [ -f "$CACHE_FILE" ]; then
  # Find the most recent entry for this file path
  LAST_ENTRY=$(grep -F "\"path\":\"${FILE_PATH}\"" "$CACHE_FILE" 2>/dev/null | tail -1 || echo "")
  if [ -n "$LAST_ENTRY" ]; then
    CACHED_MTIME=$(echo "$LAST_ENTRY" | jq -r '.mtime // empty' 2>/dev/null || echo "")
    CACHED_TS=$(echo "$LAST_ENTRY" | jq -r '.ts // empty' 2>/dev/null || echo "")
  fi
fi

if [ -n "$CACHED_MTIME" ] && [ "$CACHED_MTIME" = "$CURRENT_MTIME" ]; then
  # File hasn't changed since last read. Check failsafe TTL (if enabled).
  ENTRY_AGE=0
  if [ -n "$CACHED_TS" ]; then
    ENTRY_AGE=$(( NOW - CACHED_TS ))
  fi

  if [ "$TTL" -gt 0 ] && [ "$ENTRY_AGE" -ge "$TTL" ]; then
    # Failsafe TTL fired — assume PostCompact may have been missed.
    # Allow re-read and refresh the cache entry.
    echo "{\"path\":\"${FILE_PATH}\",\"mtime\":\"${CURRENT_MTIME}\",\"ts\":${NOW},\"tokens\":${ESTIMATED_TOKENS}}" >> "$CACHE_FILE"
    echo "{\"ts\":${NOW},\"path\":\"${FILE_PATH}\",\"tokens\":${ESTIMATED_TOKENS},\"session\":\"${SESSION_HASH}\",\"agent\":\"${AGENT_KEY}\",\"event\":\"expired\"}" >> "$STATS_FILE"
    if [ "$DIFF_MODE" = "1" ]; then
      cp "$FILE_PATH" "$SNAP_FILE"
    fi
    exit 0
  fi

  # Cache hit — file unchanged and (TTL=0 OR within failsafe TTL)
  MINUTES_AGO=$(( ENTRY_AGE / 60 ))
  echo "{\"ts\":${NOW},\"path\":\"${FILE_PATH}\",\"tokens_saved\":${ESTIMATED_TOKENS},\"session\":\"${SESSION_HASH}\",\"agent\":\"${AGENT_KEY}\",\"event\":\"hit\"}" >> "$STATS_FILE"

  # Calculate cumulative (session,agent) savings for the deny message
  SESSION_SAVED=$(grep "\"session\":\"${SESSION_HASH}\"" "$STATS_FILE" 2>/dev/null | grep "\"agent\":\"${AGENT_KEY}\"" | grep '"event":"hit"' | jq -r '.tokens_saved' 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo "$ESTIMATED_TOKENS")

  BASENAME=$(basename "$FILE_PATH")

  # Cost estimate (Sonnet $3/MTok)
  COST_INFO=""
  if command -v python3 &>/dev/null && [ "$SESSION_SAVED" -gt 0 ]; then
    COST_INFO=$(echo "$SESSION_SAVED" | python3 -c "import sys; t=int(sys.stdin.read().strip()); print(' (~\$%.4f saved at Sonnet rates)' % (t*3/1000000))" 2>/dev/null || echo "")
  fi

  # Invalidation reminder — wording adapts to whether failsafe TTL is on.
  if [ "$TTL" -gt 0 ]; then
    TTL_MIN=$(( TTL / 60 ))
    INVAL_NOTE="Cache cleared on /compact, /clear, or resume — or after ${TTL_MIN}m failsafe."
  else
    INVAL_NOTE="Cache cleared on /compact, /clear, or resume."
  fi

  REASON="read-once: ${BASENAME} (~${ESTIMATED_TOKENS} tokens) already in context (read ${MINUTES_AGO}m ago, unchanged). ${INVAL_NOTE} Session savings: ~${SESSION_SAVED} tokens${COST_INFO}."

  if [ "$MODE" = "deny" ]; then
    # Hard block — saves tokens but breaks Edit tool and parallel reads.
    # Use top-level decision:block so Claude reliably honors the deny path.
    jq -cn --arg r "$REASON" '{"decision":"block","reason":$r}'
  else
    # Warn mode (default) — allow the read with advisory message.
    # Prevents Edit tool deadlock (Edit requires a prior Read to succeed)
    # and parallel read cascade failures (one deny kills all parallel reads).
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "${REASON}"
  }
}
EOF
  fi
  exit 0
fi

# Cache miss or file changed
if [ -n "$CACHED_MTIME" ] && [ "$DIFF_MODE" = "1" ] && [ -f "$SNAP_FILE" ]; then
  # File changed + diff mode enabled + we have a snapshot
  # Compute diff and deny with just the changes if small enough
  DIFF_OUTPUT=$(diff -u "$SNAP_FILE" "$FILE_PATH" 2>/dev/null || true)
  DIFF_LINES=$(echo "$DIFF_OUTPUT" | wc -l | tr -d ' ')

  if [ -n "$DIFF_OUTPUT" ] && [ "$DIFF_LINES" -le "$DIFF_MAX" ]; then
    # Diff is small enough — deny with diff in the reason
    # Update cache and snapshot
    echo "{\"path\":\"${FILE_PATH}\",\"mtime\":\"${CURRENT_MTIME}\",\"ts\":${NOW},\"tokens\":${ESTIMATED_TOKENS}}" >> "$CACHE_FILE"
    cp "$FILE_PATH" "$SNAP_FILE"

    DIFF_TOKENS=$(( DIFF_LINES * 10 ))
    TOKENS_SAVED=$(( ESTIMATED_TOKENS - DIFF_TOKENS ))
    if [ "$TOKENS_SAVED" -lt 0 ]; then TOKENS_SAVED=0; fi

    echo "{\"ts\":${NOW},\"path\":\"${FILE_PATH}\",\"tokens_saved\":${TOKENS_SAVED},\"session\":\"${SESSION_HASH}\",\"agent\":\"${AGENT_KEY}\",\"event\":\"diff\"}" >> "$STATS_FILE"

    BASENAME=$(basename "$FILE_PATH")
    # Build JSON with properly escaped diff
    REASON_PREFIX="read-once: ${BASENAME} changed since last read. You already have the previous version in context. Here are only the changes (saving ~${TOKENS_SAVED} tokens):\\n\\n"
    REASON_SUFFIX="\\n\\nApply this diff mentally to your cached version of the file."
    # Use python3 to safely escape the diff for JSON embedding
    REASON=$(echo "$DIFF_OUTPUT" | python3 -c "
import sys, json
diff = sys.stdin.read()
prefix = '''${REASON_PREFIX}'''
suffix = '''${REASON_SUFFIX}'''
# json.dumps gives us a quoted escaped string; strip the quotes
escaped_diff = json.dumps(diff)[1:-1]
print(prefix + escaped_diff + suffix)
" 2>/dev/null)

    if [ -z "$REASON" ]; then
      # Python failed — fall through to full re-read
      :
    else
      if [ "$MODE" = "deny" ]; then
        # Use top-level decision:block so Claude reliably honors the deny path.
        jq -cn --arg r "$REASON" '{"decision":"block","reason":$r}'
      else
        cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "${REASON}"
  }
}
EOF
      fi
      exit 0
    fi
    # Python failed — fall through to full re-read
  fi
  # Diff too large or Python failed — fall through to full re-read
fi

# Record the read
echo "{\"path\":\"${FILE_PATH}\",\"mtime\":\"${CURRENT_MTIME}\",\"ts\":${NOW},\"tokens\":${ESTIMATED_TOKENS}}" >> "$CACHE_FILE"

# Save snapshot for future diffs
if [ "$DIFF_MODE" = "1" ]; then
  cp "$FILE_PATH" "$SNAP_FILE"
fi

# Log the event
if [ -n "$CACHED_MTIME" ]; then
  EVENT="changed"
else
  EVENT="miss"
fi
echo "{\"ts\":${NOW},\"path\":\"${FILE_PATH}\",\"tokens\":${ESTIMATED_TOKENS},\"session\":\"${SESSION_HASH}\",\"agent\":\"${AGENT_KEY}\",\"event\":\"${EVENT}\"}" >> "$STATS_FILE"

# Allow the read
exit 0
