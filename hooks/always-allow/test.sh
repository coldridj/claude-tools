#!/bin/bash
# Tests for always-allow hook
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/hook.sh"
PASS=0
FAIL=0

run_hook() {
  local command="$1"
  local stdout_file stderr_file rc
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  local input
  input=$(jq -cn --arg cmd "$command" '{"tool_name":"Bash","tool_input":{"command":$cmd}}')
  if echo "$input" | "${@:2}" bash "$HOOK" >"$stdout_file" 2>"$stderr_file"; then
    rc=0
  else
    rc=$?
  fi
  HOOK_STDOUT=$(cat "$stdout_file")
  HOOK_STDERR=$(cat "$stderr_file")
  HOOK_RC=$rc
  rm -f "$stdout_file" "$stderr_file"
}

assert_ignored() {
  local desc="$1"
  local command="${2:-$1}"
  run_hook "$command" "${@:3}"
  if [ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected clean allow, got rc=$HOOK_RC stdout='$HOOK_STDOUT' stderr='$HOOK_STDERR')"
  fi
}

assert_allowed() {
  local desc="$1"
  local command="${2:-$1}"
  run_hook "$command" "${@:3}"
  if [ "$HOOK_RC" -eq 0 ] && [ "$HOOK_STDOUT" == '{"decision": "allow"}' ] && [ -z "$HOOK_STDERR" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected clean allow, got rc=$HOOK_RC stdout='$HOOK_STDOUT' stderr='$HOOK_STDERR')"
  fi
}

echo "=== always-allow tests ==="

echo ""
echo "--- Non-Bash tools (should pass through) ---"
assert_ignored "Read tool ignored" "cat foo.txt"
TOOL_INPUT='{"tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}'
RESULT=$(echo "$TOOL_INPUT" | bash "$HOOK" 2>/dev/null) || true
if [ -z "$RESULT" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: Non-Bash tool passes through"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Non-Bash tool should pass through"
fi

echo ""
assert_allowed "scripts/build.sh" "scripts/build.sh"
assert_allowed "scripts/build*.sh" "scripts/build-frontend.sh"
assert_ignored "scripts/build/*.sh" "scripts/build/frontend.sh"
assert_ignored "woo/scripts/build*" "woo/scripts/build-frontend.sh"
assert_allowed "scripts/inspect.sh" "scripts/inspect.sh woo yay"
assert_ignored "scripts/build.sh && echo done"

echo ""
echo "--- Multi-command separators (should be ignored) ---"
assert_ignored "pipe separator" "scripts/build.sh | tee build.log"
assert_ignored "semicolon separator" "scripts/build.sh; ls"
assert_ignored "OR separator" "scripts/build.sh || echo failed"
assert_ignored "newline separator" $'scripts/build.sh\necho done'
assert_ignored "newline with dangerous suffix" $'scripts/inspect.sh foo\nrm -rf /'

echo ""
echo "--- Background commands (should be ignored) ---"
BG_STDOUT=$(mktemp)
jq -cn --arg cmd "scripts/build.sh" \
  '{"tool_name":"Bash","tool_input":{"command":$cmd,"run_in_background":true}}' \
  | bash "$HOOK" >"$BG_STDOUT" 2>/dev/null || true
BG_RESULT=$(cat "$BG_STDOUT"); rm -f "$BG_STDOUT"
if [ -z "$BG_RESULT" ]; then
  PASS=$((PASS + 1)); echo "  PASS: background command not auto-allowed"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: background command should not be auto-allowed (got: $BG_RESULT)"
fi

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "Total: $((PASS + FAIL)) tests"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
