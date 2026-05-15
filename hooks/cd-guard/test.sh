#!/usr/bin/env bash
# Tests for cd-guard hook.
#
# Each test feeds JSON stdin to hook.sh and asserts the exit code:
#   0 — allow (pass-through)
#   2 — block
set -euo pipefail
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="${1:-$HOOK_DIR/hook.sh}"

ok()   { printf '\033[32m PASS \033[0m %s\n' "$1"; }
fail() { printf '\033[31m FAIL \033[0m %s\n' "$1"; FAILURES=$(( FAILURES + 1 )); }
FAILURES=0

expect_allow() {
  local label="$1" input="$2"
  local code=0
  printf '%s' "$input" | bash "$HOOK" >/dev/null 2>&1 || code=$?
  if [ "$code" -eq 0 ]; then ok "$label"
  else fail "$label — expected ALLOW, got exit $code"; fi
}

expect_block() {
  local label="$1" input="$2"
  local code=0
  printf '%s' "$input" | bash "$HOOK" >/dev/null 2>&1 || code=$?
  if [ "$code" -eq 2 ]; then ok "$label"
  else fail "$label — expected BLOCK (exit 2), got exit $code"; fi
}

echo "=== cd-guard tests ==="

echo
echo "--- Top-level cd: BLOCK ---"

expect_block "cd at start of command" \
  '{"tool_name":"Bash","tool_input":{"command":"cd /tmp"}}'

expect_block "cd with relative dir" \
  '{"tool_name":"Bash","tool_input":{"command":"cd foo"}}'

expect_block "cd with leading whitespace" \
  '{"tool_name":"Bash","tool_input":{"command":"  cd /tmp"}}'

expect_block "cd after `;` separator" \
  '{"tool_name":"Bash","tool_input":{"command":"echo hi; cd /tmp"}}'

expect_block "cd after `&&`" \
  '{"tool_name":"Bash","tool_input":{"command":"true && cd /tmp"}}'

expect_block "cd after `||`" \
  '{"tool_name":"Bash","tool_input":{"command":"false || cd /tmp"}}'

expect_block "cd after single `&` (background)" \
  '{"tool_name":"Bash","tool_input":{"command":"sleep 1 & cd /tmp"}}'

expect_block "cd after pipe (semantically nonsense, still blocked)" \
  '{"tool_name":"Bash","tool_input":{"command":"echo /tmp | cd"}}'

expect_block "cd split across line continuation" \
  '{"tool_name":"Bash","tool_input":{"command":"cd \\\n/tmp"}}'

expect_block "cd - (cd back)" \
  '{"tool_name":"Bash","tool_input":{"command":"cd -"}}'

expect_block "cd with no arg (cd to HOME)" \
  '{"tool_name":"Bash","tool_input":{"command":"cd"}}'

echo
echo "--- Subshell / substitution cd: ALLOW ---"

expect_allow "cd inside parenthesised subshell" \
  '{"tool_name":"Bash","tool_input":{"command":"(cd /tmp && ls)"}}'

expect_allow "cd inside command substitution" \
  '{"tool_name":"Bash","tool_input":{"command":"out=$(cd /tmp && pwd)"}}'

expect_allow "cd inside backtick substitution" \
  '{"tool_name":"Bash","tool_input":{"command":"out=`cd /tmp && pwd`"}}'

expect_allow "cd inside brace group (still parent shell, but rare and tolerated)" \
  '{"tool_name":"Bash","tool_input":{"command":"{ cd /tmp; ls; }"}}'

expect_allow "bash -c with cd inside single quotes" \
  '{"tool_name":"Bash","tool_input":{"command":"bash -c '\''cd /tmp && ls'\''"}}'

expect_allow "bash -c with cd inside double quotes" \
  '{"tool_name":"Bash","tool_input":{"command":"bash -c \"cd /tmp && ls\""}}'

echo
echo "--- cd inside argument text: ALLOW ---"

expect_allow "echo with 'cd' substring inside double quotes" \
  '{"tool_name":"Bash","tool_input":{"command":"echo \"did cd to dir\""}}'

expect_allow "echo with 'cd' substring inside single quotes" \
  '{"tool_name":"Bash","tool_input":{"command":"echo '\''run cd to /tmp'\''"}}'

expect_allow "command argument containing 'cd-tool'" \
  '{"tool_name":"Bash","tool_input":{"command":"./cd-tool --help"}}'

echo
echo "--- Canonical alternatives: ALLOW ---"

expect_allow "git -C <subdir>" \
  '{"tool_name":"Bash","tool_input":{"command":"git -C foo log --oneline"}}'

expect_allow "absolute path" \
  '{"tool_name":"Bash","tool_input":{"command":"ls /tmp"}}'

expect_allow "repo-relative path" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .gitignore"}}'

echo
echo "--- Non-Bash tools: pass-through ---"

expect_allow "Read tool — pass-through" \
  '{"tool_name":"Read","tool_input":{"file_path":"/tmp/whatever"}}'

expect_allow "Edit tool — pass-through" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x","old_string":"a","new_string":"b"}}'

echo
echo "--- Disabled via env var: ALLOW even top-level cd ---"

# Run with CD_GUARD_DISABLED=1 inline.
code=0
printf '{"tool_name":"Bash","tool_input":{"command":"cd /tmp"}}' \
  | env CD_GUARD_DISABLED=1 bash "$HOOK" >/dev/null 2>&1 || code=$?
if [ "$code" -eq 0 ]; then
  ok "CD_GUARD_DISABLED=1 — top-level cd passes through"
else
  fail "CD_GUARD_DISABLED=1 — top-level cd should pass, got exit $code"
fi

echo
echo "=================================="
if [ "$FAILURES" -eq 0 ]; then
  printf '\033[32mAll tests passed\033[0m\n'
  exit 0
else
  printf '\033[31m%d test(s) failed\033[0m\n' "$FAILURES"
  exit 1
fi
