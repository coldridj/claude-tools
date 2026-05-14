#!/bin/bash
# Tests for scratch-allow hook.
#
# The hook emits `permissionDecision: allow` for Write/Edit/MultiEdit
# calls whose target is inside $CLAUDE_SESSION_SCRATCH. Everything else
# passes through silently.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="${1:-$SCRIPT_DIR/hook.sh}"
PASS=0
FAIL=0

ALLOW_JSON='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'

# Run with isolated env vars; populate HOOK_RC + HOOK_STDOUT + HOOK_STDERR.
run_scratch() {
  local tool="$1" file_path="$2" session_scratch="${3:-}"
  local input
  input=$(jq -cn --arg t "$tool" --arg p "$file_path" \
    '{"tool_name":$t,"tool_input":{"file_path":$p}}')
  local stdout_file stderr_file rc=0
  stdout_file=$(mktemp); stderr_file=$(mktemp)
  local env_extras=()
  [ -n "$session_scratch" ] && env_extras+=("CLAUDE_SESSION_SCRATCH=$session_scratch")
  env_extras+=("CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR_FIXTURE:-/test/project}")
  if echo "$input" | env "${env_extras[@]}" bash "$HOOK" >"$stdout_file" 2>"$stderr_file"; then
    rc=0
  else
    rc=$?
  fi
  HOOK_STDOUT=$(cat "$stdout_file")
  HOOK_STDERR=$(cat "$stderr_file")
  HOOK_RC=$rc
  rm -f "$stdout_file" "$stderr_file"
}

assert_allow() {
  local desc="$1"
  if [ "$HOOK_RC" -eq 0 ] && [ "$HOOK_STDOUT" = "$ALLOW_JSON" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (rc=$HOOK_RC stdout='$HOOK_STDOUT' stderr='$HOOK_STDERR')"
  fi
}

assert_pass_through() {
  local desc="$1"
  if [ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_STDOUT" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (rc=$HOOK_RC stdout='$HOOK_STDOUT' stderr='$HOOK_STDERR')"
  fi
}

echo "=== scratch-allow tests ==="

# Create a scratch dir fixture so realpath -m resolves consistently.
SCRATCH_FIXTURE=$(mktemp -d)
echo "Using scratch fixture: $SCRATCH_FIXTURE"

echo
echo "--- Inside scratch: Write/Edit/MultiEdit → allow ---"

run_scratch "Write" "$SCRATCH_FIXTURE/file.txt" "$SCRATCH_FIXTURE"
assert_allow "Write to file inside scratch root (absolute path)"

run_scratch "Edit" "$SCRATCH_FIXTURE/dir/file.txt" "$SCRATCH_FIXTURE"
assert_allow "Edit nested file inside scratch root"

run_scratch "MultiEdit" "$SCRATCH_FIXTURE/another.md" "$SCRATCH_FIXTURE"
assert_allow "MultiEdit file inside scratch root"

# A path one segment off the scratch root must NOT match.
SIBLING=$(mktemp -d)
run_scratch "Write" "$SIBLING/file.txt" "$SCRATCH_FIXTURE"
assert_pass_through "Write to a sibling scratch dir (not inside session root)"
rmdir "$SIBLING" 2>/dev/null || true

# Prefix-collision: $SCRATCH_FIXTURE = /tmp/x.abc; target = /tmp/x.abc-other/y
# must NOT match.
COLLISION_BASE=$(mktemp -d)
COLLISION_TARGET="${COLLISION_BASE}-collision"
run_scratch "Write" "$COLLISION_TARGET/y.txt" "$COLLISION_BASE"
assert_pass_through "Prefix-collision: '<scratch>-collision/' is not inside '<scratch>'"
rmdir "$COLLISION_BASE" 2>/dev/null || true

echo
echo "--- Outside scratch: Write/Edit pass through ---"

run_scratch "Write" "/test/project/src/app.cs" "$SCRATCH_FIXTURE"
assert_pass_through "Write to project-source file"

run_scratch "Edit" "/etc/passwd" "$SCRATCH_FIXTURE"
assert_pass_through "Edit on out-of-zone file passes through (path-guard handles the block)"

echo
echo "--- Wrong tool: pass through ---"

run_scratch "Read" "$SCRATCH_FIXTURE/file.txt" "$SCRATCH_FIXTURE"
assert_pass_through "Read tool input passes through (out of scope)"

run_scratch "Bash" "$SCRATCH_FIXTURE/file.txt" "$SCRATCH_FIXTURE"
assert_pass_through "Bash tool input passes through (out of scope)"

echo
echo "--- Missing CLAUDE_SESSION_SCRATCH: pass through ---"

run_scratch "Write" "$SCRATCH_FIXTURE/file.txt" ""
assert_pass_through "CLAUDE_SESSION_SCRATCH unset → pass-through"

echo
echo "--- Symlink resolution ---"

LINK_DIR=$(mktemp -d)
ln -s "$SCRATCH_FIXTURE/inner.txt" "$LINK_DIR/redirect"
run_scratch "Write" "$LINK_DIR/redirect" "$SCRATCH_FIXTURE"
assert_allow "Write through symlink that resolves into scratch"
rm -rf "$LINK_DIR"

# Symlink pointing out of scratch: realpath -m resolves it, prefix check
# fails, pass through.
LINK_DIR=$(mktemp -d)
ln -s "/etc/passwd" "$LINK_DIR/redirect"
run_scratch "Write" "$LINK_DIR/redirect" "$SCRATCH_FIXTURE"
assert_pass_through "Write through symlink that resolves OUT of scratch"
rm -rf "$LINK_DIR"

echo
echo "--- SCRATCH_ALLOW_DISABLED short-circuits ---"

input=$(jq -cn --arg p "$SCRATCH_FIXTURE/file.txt" \
  '{"tool_name":"Write","tool_input":{"file_path":$p}}')
result=$(echo "$input" \
  | env SCRATCH_ALLOW_DISABLED=1 CLAUDE_SESSION_SCRATCH="$SCRATCH_FIXTURE" \
        CLAUDE_PROJECT_DIR=/test/project \
        bash "$HOOK" 2>/dev/null) || true
if [ -z "$result" ]; then
  PASS=$((PASS + 1)); echo "  PASS: SCRATCH_ALLOW_DISABLED=1 short-circuits"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: SCRATCH_ALLOW_DISABLED=1 (got: $result)"
fi

echo
echo "--- jq missing → fail-open ---"

EMPTY=$(mktemp -d)
BASH_BIN="$(command -v bash)"
input=$(jq -cn --arg p "$SCRATCH_FIXTURE/file.txt" \
  '{"tool_name":"Write","tool_input":{"file_path":$p}}')
err_file=$(mktemp); out_file=$(mktemp)
echo "$input" \
  | PATH="$EMPTY" HOME="$(mktemp -d)" CLAUDE_SESSION_SCRATCH="$SCRATCH_FIXTURE" \
    CLAUDE_PROJECT_DIR=/test/project \
    "$BASH_BIN" "$HOOK" >"$out_file" 2>"$err_file" || true
out=$(cat "$out_file"); err=$(cat "$err_file")
if [ -z "$out" ] && [[ "$err" == *"jq not found"* ]]; then
  PASS=$((PASS + 1)); echo "  PASS: jq missing → fail-open with warning"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: jq missing (stdout='$out' stderr='$err')"
fi
rm -rf "$EMPTY"; rm -f "$out_file" "$err_file"

# Cleanup
rmdir "$SCRATCH_FIXTURE" 2>/dev/null || rm -rf "$SCRATCH_FIXTURE"

echo
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "Total: $((PASS + FAIL)) tests"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
