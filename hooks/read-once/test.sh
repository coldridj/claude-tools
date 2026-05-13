#!/bin/bash
# read-once test suite
# Tests the PreToolUse hook behavior

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="${SCRIPT_DIR}/hook.sh"
PASS=0
FAIL=0
TOTAL=0

# Use a temp directory for test isolation
TEST_DIR=$(mktemp -d)
TEST_FILE="${TEST_DIR}/test-file.txt"
echo "Hello, world!" > "$TEST_FILE"

# Override HOME so $HOME/.claude/read-once stats live inside the test dir,
# and CLAUDE_PROJECT_DIR so the per-session cache (which uses
# $CLAUDE_PROJECT_DIR/$CLAUDE_SCRATCH_ROOT/<sid>/read-once) is also
# isolated to the test dir instead of polluting the user's working tree.
export HOME="$TEST_DIR"
export CLAUDE_PROJECT_DIR="$TEST_DIR"
mkdir -p "${TEST_DIR}/.claude/read-once"

# Test session ID
SESSION="test-session-$$"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_eq() {
  TOTAL=$((TOTAL + 1))
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_contains() {
  TOTAL=$((TOTAL + 1))
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc"
    echo "    expected to contain: $needle"
    echo "    actual: $haystack"
  fi
}

assert_empty() {
  TOTAL=$((TOTAL + 1))
  local desc="$1" actual="$2"
  if [ -z "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc"
    echo "    expected empty, got: $actual"
  fi
}

make_input() {
  local tool="$1" path="$2" session="${3:-$SESSION}" offset="${4:-}" limit="${5:-}" agent="${6:-}"
  local json="{\"tool_name\":\"${tool}\",\"tool_input\":{\"file_path\":\"${path}\""
  if [ -n "$offset" ]; then
    json="${json},\"offset\":${offset}"
  fi
  if [ -n "$limit" ]; then
    json="${json},\"limit\":${limit}"
  fi
  json="${json}},\"session_id\":\"${session}\""
  if [ -n "$agent" ]; then
    json="${json},\"agent_id\":\"${agent}\""
  fi
  # PreToolUse hook_event_name so the merged hook's dispatch case-statement
  # routes this at the read-tracking path.
  json="${json},\"hook_event_name\":\"PreToolUse\"}"
  echo "$json"
}

run_hook() {
  echo "$1" | bash "$HOOK" 2>/dev/null || true
}

echo "read-once test suite"
echo "===================="
echo ""

# --- Test 1: Non-Read tool passes through ---
echo "1. Non-Read tools"
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s1"}' | bash "$HOOK" 2>/dev/null || true)
assert_empty "Bash tool passes through (no output)" "$OUTPUT"

OUTPUT=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x"},"session_id":"s1"}' | bash "$HOOK" 2>/dev/null || true)
assert_empty "Write tool passes through" "$OUTPUT"

# --- Test 2: First read of a file (cache miss) ---
echo ""
echo "2. First read (cache miss)"
OUTPUT=$(run_hook "$(make_input Read "$TEST_FILE")")
assert_empty "First read passes through (no output)" "$OUTPUT"

# --- Test 3: Second read of same file (cache hit — warn mode default) ---
echo ""
echo "3. Second read (cache hit — warn mode, should allow with advisory)"
OUTPUT=$(run_hook "$(make_input Read "$TEST_FILE")")
assert_contains "Warn mode: allows with advisory" "allow" "$OUTPUT"
assert_contains "Message mentions already in context" "already in context" "$OUTPUT"

# --- Test 3b: Deny mode blocks the read ---
echo ""
echo "3b. Second read (cache hit — deny mode, should block)"
export READ_ONCE_MODE=deny
OUTPUT=$(run_hook "$(make_input Read "$TEST_FILE")")
assert_contains "Deny mode: blocks with decision:block" "block" "$OUTPUT"
assert_contains "Deny mode: mentions already in context" "already in context" "$OUTPUT"
# Verify robust response format (top-level decision, not hookSpecificOutput — see claude-code#37597)
TOTAL=$((TOTAL + 1))
if echo "$OUTPUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  echo "PASS: Deny mode uses robust top-level decision format"
  PASS=$((PASS + 1))
else
  echo "FAIL: Deny mode should use top-level decision:block, not hookSpecificOutput"
  FAIL=$((FAIL + 1))
fi
unset READ_ONCE_MODE

# --- Test 4: File changes between reads ---
echo ""
echo "4. File modified between reads (should allow re-read)"
sleep 1  # ensure mtime changes
echo "Modified content" > "$TEST_FILE"
OUTPUT=$(run_hook "$(make_input Read "$TEST_FILE")")
assert_empty "Modified file allowed through" "$OUTPUT"

# --- Test 5: Different session, same file ---
echo ""
echo "5. Different session (independent cache)"
OUTPUT=$(run_hook "$(make_input Read "$TEST_FILE" "different-session")")
assert_empty "Different session allows read" "$OUTPUT"

# --- Test 6: Nonexistent file ---
echo ""
echo "6. Nonexistent file"
OUTPUT=$(run_hook "$(make_input Read "/nonexistent/file.txt")")
assert_empty "Nonexistent file passes through" "$OUTPUT"

# --- Test 7: Partial reads (offset/limit) should not be cached ---
echo ""
echo "7. Partial reads bypass cache"
# Create a fresh file so no prior cache
PARTIAL_FILE="${TEST_DIR}/partial.txt"
echo "line1\nline2\nline3\nline4\nline5" > "$PARTIAL_FILE"

# First full read
OUTPUT=$(run_hook "$(make_input Read "$PARTIAL_FILE")")
assert_empty "Full read passes through" "$OUTPUT"

# Read with offset — should pass through even though file is cached
OUTPUT=$(run_hook "$(make_input Read "$PARTIAL_FILE" "$SESSION" 10)")
assert_empty "Read with offset passes through" "$OUTPUT"

# Read with limit — should pass through
OUTPUT=$(run_hook "$(make_input Read "$PARTIAL_FILE" "$SESSION" "" 50)")
assert_empty "Read with limit passes through" "$OUTPUT"

# Read with both offset and limit
OUTPUT=$(run_hook "$(make_input Read "$PARTIAL_FILE" "$SESSION" 10 50)")
assert_empty "Read with offset+limit passes through" "$OUTPUT"

# Full re-read should still be intercepted (was cached from first read)
OUTPUT=$(run_hook "$(make_input Read "$PARTIAL_FILE")")
assert_contains "Full re-read intercepted (warn mode)" "allow" "$OUTPUT"
assert_contains "Full re-read advisory message" "already in context" "$OUTPUT"

# --- Test 8: Missing fields ---
echo ""
echo "8. Missing/empty fields"
OUTPUT=$(echo '{"tool_name":"Read","tool_input":{},"session_id":"s1"}' | bash "$HOOK" 2>/dev/null || true)
assert_empty "Missing file_path passes through" "$OUTPUT"

OUTPUT=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}' | bash "$HOOK" 2>/dev/null || true)
assert_empty "Missing session_id passes through" "$OUTPUT"

# --- Test 9: Stats file gets written ---
echo ""
echo "9. Stats tracking"
STATS="${TEST_DIR}/.claude/read-once/stats.jsonl"
if [ -f "$STATS" ]; then
  HIT_COUNT=$(grep -c '"event":"hit"' "$STATS" 2>/dev/null || true)
  MISS_COUNT=$(grep -c '"event":"miss"' "$STATS" 2>/dev/null || true)
  assert_eq "Stats has hit events" "1" "$([ "$HIT_COUNT" -gt 0 ] && echo 1 || echo 0)"
  assert_eq "Stats has miss events" "1" "$([ "$MISS_COUNT" -gt 0 ] && echo 1 || echo 0)"
else
  TOTAL=$((TOTAL + 2))
  FAIL=$((FAIL + 2))
  echo "  ✗ Stats file not found"
fi

# Test 10 (TTL-with-default-1200s assertions) removed — the current hook
# defaults to READ_ONCE_TTL=0 (deterministic-only) and emits "Cache cleared
# on /compact, /clear, or resume" rather than the upstream "Re-read allowed
# after Xm" wording. Custom-TTL coverage is in Test 11 below; the expired-
# event stats assertion is folded in there.

# --- Test 11: Custom TTL via environment variable ---
echo ""
echo "11. Custom TTL via READ_ONCE_TTL"

CTL_FILE="${TEST_DIR}/custom-ttl.txt"
echo "Custom TTL content" > "$CTL_FILE"
CTL_SESSION="custom-ttl-$$"

# Set very short TTL (2 seconds)
export READ_ONCE_TTL=2

# First read
OUTPUT=$(run_hook "$(make_input Read "$CTL_FILE" "$CTL_SESSION")")
assert_empty "Custom TTL: first read passes" "$OUTPUT"

# Immediate re-read — should be intercepted (warn mode)
OUTPUT=$(run_hook "$(make_input Read "$CTL_FILE" "$CTL_SESSION")")
assert_contains "Custom TTL: re-read intercepted within 2s" "already in context" "$OUTPUT"

# Wait for TTL to expire
sleep 3

# Re-read after TTL — should pass
OUTPUT=$(run_hook "$(make_input Read "$CTL_FILE" "$CTL_SESSION")")
assert_empty "Custom TTL: re-read passes after 2s TTL" "$OUTPUT"

# Expired event should be logged in stats (rolled in from removed Test 10)
EXPIRED_COUNT=$(grep -c '"event":"expired"' "$STATS" 2>/dev/null || true)
assert_eq "Custom TTL: expired event logged in stats" "1" "$([ "$EXPIRED_COUNT" -gt 0 ] && echo 1 || echo 0)"

# Reset TTL
unset READ_ONCE_TTL

# --- Test 12: READ_ONCE_DISABLED ---
echo ""
echo "12. Disable via READ_ONCE_DISABLED"

DISABLED_FILE="${TEST_DIR}/disabled-test.txt"
echo "Disabled test" > "$DISABLED_FILE"

# First read (normal)
OUTPUT=$(run_hook "$(make_input Read "$DISABLED_FILE")")
assert_empty "Disabled: first read normal" "$OUTPUT"

# Enable disabled flag
export READ_ONCE_DISABLED=1

# Second read — should pass through even though cached
OUTPUT=$(run_hook "$(make_input Read "$DISABLED_FILE")")
assert_empty "Disabled: re-read passes when disabled" "$OUTPUT"

unset READ_ONCE_DISABLED

# --- Test 13: Changed file event tracking ---
echo ""
echo "13. Changed file event in stats"

CHANGE_FILE="${TEST_DIR}/change-track.txt"
echo "original" > "$CHANGE_FILE"
CHANGE_SESSION="change-session-$$"

# First read
run_hook "$(make_input Read "$CHANGE_FILE" "$CHANGE_SESSION")" > /dev/null

# Modify file
sleep 1
echo "modified" > "$CHANGE_FILE"

# Second read after change
run_hook "$(make_input Read "$CHANGE_FILE" "$CHANGE_SESSION")" > /dev/null

CHANGED_COUNT=$(grep -c '"event":"changed"' "$STATS" 2>/dev/null || true)
assert_eq "Changed file event logged" "1" "$([ "$CHANGED_COUNT" -gt 0 ] && echo 1 || echo 0)"

# --- Test 14: Diff mode — small change shows diff instead of full re-read ---
echo ""
echo "14. Diff mode — small change shows diff"

DIFF_FILE="${TEST_DIR}/diff-test.txt"
cat > "$DIFF_FILE" << 'CONTENT'
line 1: hello
line 2: world
line 3: foo
line 4: bar
line 5: baz
CONTENT
DIFF_SESSION="diff-session-$$"
export READ_ONCE_DIFF=1

# First read — should pass through and create snapshot
OUTPUT=$(run_hook "$(make_input Read "$DIFF_FILE" "$DIFF_SESSION")")
assert_empty "Diff: first read passes through" "$OUTPUT"

# Verify snapshot was created. Current hook layout:
#   <project>/<scratch-root>/<sid>/read-once/snapshots/<agent>-<path-hash>
PATH_HASH_DIFF=$(echo -n "$DIFF_FILE" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)
SNAP="${TEST_DIR}/.scratch/${DIFF_SESSION}/read-once/snapshots/main-${PATH_HASH_DIFF}"
assert_eq "Diff: snapshot file created" "1" "$([ -f "$SNAP" ] && echo 1 || echo 0)"

# Modify file with a small change
sleep 1
cat > "$DIFF_FILE" << 'CONTENT'
line 1: hello
line 2: CHANGED
line 3: foo
line 4: bar
line 5: baz
CONTENT

# Re-read — should show diff, not full re-read (warn mode: allow with diff)
OUTPUT=$(run_hook "$(make_input Read "$DIFF_FILE" "$DIFF_SESSION")")
assert_contains "Diff: intercepted with diff content (warn=allow)" "allow" "$OUTPUT"
assert_contains "Diff: mentions changes" "changed since last read" "$OUTPUT"
assert_contains "Diff: includes diff markers" "CHANGED" "$OUTPUT"

# --- Test 15: Diff mode — large change falls back to full re-read ---
echo ""
echo "15. Diff mode — large change falls back to full re-read"

LARGE_DIFF_FILE="${TEST_DIR}/large-diff.txt"
LARGE_SESSION="large-diff-$$"

# Create initial file
for i in $(seq 1 50); do echo "original line $i"; done > "$LARGE_DIFF_FILE"

# First read
OUTPUT=$(run_hook "$(make_input Read "$LARGE_DIFF_FILE" "$LARGE_SESSION")")
assert_empty "Large diff: first read passes" "$OUTPUT"

# Change most lines (>40 line diff)
sleep 1
for i in $(seq 1 50); do echo "REPLACED line $i"; done > "$LARGE_DIFF_FILE"

# Re-read — diff too large, should allow full re-read
export READ_ONCE_DIFF_MAX=10
OUTPUT=$(run_hook "$(make_input Read "$LARGE_DIFF_FILE" "$LARGE_SESSION")")
assert_empty "Large diff: falls back to full re-read" "$OUTPUT"

unset READ_ONCE_DIFF_MAX

# --- Test 16: Diff mode — unchanged file still blocked normally ---
echo ""
echo "16. Diff mode — unchanged file still blocked (cache hit)"

UNCHANGED_FILE="${TEST_DIR}/unchanged-diff.txt"
echo "stable content" > "$UNCHANGED_FILE"
UNCH_SESSION="unchanged-diff-$$"

# First read
OUTPUT=$(run_hook "$(make_input Read "$UNCHANGED_FILE" "$UNCH_SESSION")")
assert_empty "Diff unchanged: first read passes" "$OUTPUT"

# Second read — unchanged, should be a normal cache hit (warn mode: allow with advisory)
OUTPUT=$(run_hook "$(make_input Read "$UNCHANGED_FILE" "$UNCH_SESSION")")
assert_contains "Diff unchanged: cache hit (warn=allow)" "allow" "$OUTPUT"
assert_contains "Diff unchanged: normal hit message" "already in context" "$OUTPUT"

# --- Test 17: Diff mode — diff event logged in stats ---
echo ""
echo "17. Diff mode — diff events in stats"

DIFF_EVENTS=$(grep -c '"event":"diff"' "$STATS" 2>/dev/null || true)
assert_eq "Diff: diff events logged in stats" "1" "$([ "$DIFF_EVENTS" -gt 0 ] && echo 1 || echo 0)"

# --- Test 18: Diff mode disabled — changed file gets full re-read ---
echo ""
echo "18. Diff mode disabled — changed file gets full re-read"

NODIFF_FILE="${TEST_DIR}/nodiff-test.txt"
echo "original" > "$NODIFF_FILE"
NODIFF_SESSION="nodiff-session-$$"

unset READ_ONCE_DIFF

# First read
OUTPUT=$(run_hook "$(make_input Read "$NODIFF_FILE" "$NODIFF_SESSION")")
assert_empty "No diff: first read passes" "$OUTPUT"

# Modify
sleep 1
echo "modified" > "$NODIFF_FILE"

# Re-read without diff mode — should allow full re-read (changed event)
OUTPUT=$(run_hook "$(make_input Read "$NODIFF_FILE" "$NODIFF_SESSION")")
assert_empty "No diff: changed file gets full re-read" "$OUTPUT"

# --- Group 19: Cost estimates in deny message ---
echo ""
echo "--- Group 19: Cost estimates in deny message ---"

COST_SESSION="test-cost-$$"
COST_FILE="${TEST_DIR}/cost-test.txt"
printf '%0.s.' {1..4000} > "$COST_FILE"  # ~4000 bytes = ~1700 tokens

# First read
OUTPUT=$(run_hook "$(make_input Read "$COST_FILE" "$COST_SESSION")")
assert_empty "Cost: first read passes" "$OUTPUT"

# Re-read — should include cost info in advisory
OUTPUT=$(run_hook "$(make_input Read "$COST_FILE" "$COST_SESSION")")
assert_contains "Cost: advisory includes Sonnet cost" "Sonnet" "$OUTPUT"

# Groups 20 and 21 (Stats CLI / Verify command) removed — they probed an
# upstream `./read-once` wrapper with an `~/.claude/read-once/` install
# layout. In claude-tools the wrapper lives at `read-once.sh` and the
# hook is symlinked via the suite-level installer; the `verify` /
# `install` subcommands no longer apply.

# --- PostCompact / SessionStart(compact) dispatch ---
# After the compact.sh → hook.sh merge, the same hook.sh handles both
# PreToolUse and the cache-clear events. These tests exercise both the
# PostCompact route and the SessionStart(matcher=compact) fallback by
# feeding the merged hook each `hook_event_name` value.

echo ""
echo "--- PostCompact dispatch (merged into hook.sh) ---"

# Test: PostCompact clears session cache
echo "test-content-line-1" > "$TEST_FILE"
RESULT=$(run_hook "$(make_input Read "$TEST_FILE" "$SESSION")")
assert_empty "compact: pre-seed first read" "$RESULT"

# Second read should hit cache
sleep 1
RESULT=$(run_hook "$(make_input Read "$TEST_FILE" "$SESSION")")
assert_contains "compact: pre-seed cache hit" "already in context" "$RESULT"

# Run PostCompact
COMPACT_RESULT=$(echo '{"session_id":"'"$SESSION"'","hook_event_name":"PostCompact","trigger":"auto","compact_summary":"test summary"}' | bash "$HOOK")
assert_empty "compact: hook exits cleanly" "$COMPACT_RESULT"

# After compaction, re-read should be allowed (cache cleared)
RESULT=$(run_hook "$(make_input Read "$TEST_FILE" "$SESSION")")
assert_empty "compact: re-read allowed after compaction" "$RESULT"

# Test: compact logs event to stats
STATS_FILE="${TEST_DIR}/.claude/read-once/stats.jsonl"
TOTAL=$((TOTAL + 1))
if [ -f "$STATS_FILE" ] && grep -q '"event":"compact"' "$STATS_FILE"; then
  PASS=$((PASS + 1))
  echo "  ✓ compact: logs compaction event to stats"
else
  FAIL=$((FAIL + 1))
  echo "  ✗ compact: should log compaction event to stats"
fi

# Test: empty session_id exits cleanly (no cache work, no stats write)
RESULT=$(echo '{"session_id":"","hook_event_name":"PostCompact"}' | bash "$HOOK")
assert_empty "compact: empty session_id exits cleanly" "$RESULT"

# Test: missing session_id exits cleanly
RESULT=$(echo '{"hook_event_name":"PostCompact"}' | bash "$HOOK")
assert_empty "compact: missing session_id exits cleanly" "$RESULT"

# Test: compact clears the per-session snapshots dir alongside the cache.
# The hook stores snapshots at <project>/<scratch-root>/<sid>/read-once/snapshots/.
# Seed a diff-mode read so the hook creates a real snapshot, then fire
# PostCompact and assert the per-session directory is gone.
SNAP_SESSION="snap-session-$$"
SNAP_FILE="${TEST_DIR}/snap-test.txt"
echo "snap-content" > "$SNAP_FILE"
EXPECTED_SESSION_DIR="${TEST_DIR}/.scratch/${SNAP_SESSION}/read-once"
export READ_ONCE_DIFF=1
run_hook "$(make_input Read "$SNAP_FILE" "$SNAP_SESSION")" > /dev/null
TOTAL=$((TOTAL + 1))
if [ -d "${EXPECTED_SESSION_DIR}/snapshots" ]; then
  PASS=$((PASS + 1))
  echo "  ✓ compact: setup — snapshot dir created"
else
  FAIL=$((FAIL + 1))
  echo "  ✗ compact: setup — snapshot dir not created at ${EXPECTED_SESSION_DIR}/snapshots"
fi

echo '{"session_id":"'"$SNAP_SESSION"'","hook_event_name":"PostCompact"}' | bash "$HOOK"

TOTAL=$((TOTAL + 1))
if [ ! -d "$EXPECTED_SESSION_DIR" ]; then
  PASS=$((PASS + 1))
  echo "  ✓ compact: clears cache+snapshots dir"
else
  FAIL=$((FAIL + 1))
  echo "  ✗ compact: session cache dir survived at $EXPECTED_SESSION_DIR"
fi
unset READ_ONCE_DIFF

# Test: SessionStart with matcher=compact takes the same path
echo "ss-content" > "${TEST_DIR}/ss-file.txt"
SS_SESSION="ss-session-$$"
RESULT=$(run_hook "$(make_input Read "${TEST_DIR}/ss-file.txt" "$SS_SESSION")")
assert_empty "SessionStart(compact): pre-seed first read" "$RESULT"
sleep 1
RESULT=$(run_hook "$(make_input Read "${TEST_DIR}/ss-file.txt" "$SS_SESSION")")
assert_contains "SessionStart(compact): pre-seed cache hit" "already in context" "$RESULT"
# Fire SessionStart with compact source
echo '{"session_id":"'"$SS_SESSION"'","hook_event_name":"SessionStart","source":"compact"}' | bash "$HOOK"
RESULT=$(run_hook "$(make_input Read "${TEST_DIR}/ss-file.txt" "$SS_SESSION")")
assert_empty "SessionStart(compact): re-read allowed after clear" "$RESULT"

# Test: compact doesn't affect other sessions
OTHER_SESSION="other-session-$$"
echo "other-content" > "${TEST_DIR}/other-file.txt"
RESULT=$(run_hook "$(make_input Read "${TEST_DIR}/other-file.txt" "$OTHER_SESSION")")
assert_empty "compact: seed other session" "$RESULT"

# Compact the original session
echo '{"session_id":"'"$SESSION"'","hook_event_name":"PostCompact"}' | bash "$HOOK"

# Other session cache should still work
sleep 1
RESULT=$(run_hook "$(make_input Read "${TEST_DIR}/other-file.txt" "$OTHER_SESSION")")
assert_contains "compact: other session cache unaffected" "already in context" "$RESULT"

# --- Subagent isolation ---
# Subagents share the parent's session_id but get distinct agent_id values.
# The hook writes per-agent cache files (<agent>.jsonl), so a parent-agent
# read should NOT produce a "cache hit" advisory for a subagent reading
# the same file in the same session.
echo ""
echo "--- Subagent isolation ---"

SUB_SESSION="subagent-session-$$"
SUB_FILE="${TEST_DIR}/sub-test.txt"
echo "subagent-isolation-content" > "$SUB_FILE"

# Main agent reads first (no agent_id → cache key "main")
RESULT=$(run_hook "$(make_input Read "$SUB_FILE" "$SUB_SESSION")")
assert_empty "subagent: main first read passes" "$RESULT"

# Same session, different agent_id → independent cache, should be a miss
RESULT=$(run_hook "$(make_input Read "$SUB_FILE" "$SUB_SESSION" "" "" subagent-A)")
assert_empty "subagent: subagent A first read passes (not cached as main)" "$RESULT"

# Subagent A's second read should hit subagent A's cache
sleep 1
RESULT=$(run_hook "$(make_input Read "$SUB_FILE" "$SUB_SESSION" "" "" subagent-A)")
assert_contains "subagent: subagent A second read intercepted" "already in context" "$RESULT"

# A third subagent_id is still a miss (per-agent isolation in both directions)
RESULT=$(run_hook "$(make_input Read "$SUB_FILE" "$SUB_SESSION" "" "" subagent-B)")
assert_empty "subagent: subagent B is independent of subagent A" "$RESULT"

# --- Summary ---
echo ""
echo "===================="
echo "Results: ${PASS}/${TOTAL} passed, ${FAIL} failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
