#!/bin/bash
# Tests for always-allow hook
#
# Two test surfaces:
#   1. Integration tests load the project's real .always-allow at $CLAUDE_PROJECT_DIR
#      (must be run from a repo root that has one). Validates end-to-end behavior.
#   2. Section-parsing tests use run_isolated, which generates an ephemeral
#      .always-allow in a temp dir, points the hook at it via CLAUDE_PROJECT_DIR,
#      and overrides HOME so the user's ~/.claude/.always-allow can't leak in.
#      These should run anywhere.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/hook.sh"
PASS=0
FAIL=0

# --- Helpers --------------------------------------------------------------

# make_input <command> <bg-bool> — emit the JSON the hook reads from stdin.
make_input() {
  jq -cn --arg cmd "$1" --argjson bg "$2" \
    '{"tool_name":"Bash","tool_input":{"command":$cmd,"run_in_background":$bg}}'
}

# run_hook <command> [bg] — exercise hook against the project's .always-allow.
run_hook() {
  local command="$1" bg="${2:-false}" stdout_file stderr_file rc input
  stdout_file=$(mktemp); stderr_file=$(mktemp)
  input=$(make_input "$command" "$bg")
  if echo "$input" | bash "$HOOK" >"$stdout_file" 2>"$stderr_file"; then
    rc=0
  else
    rc=$?
  fi
  HOOK_STDOUT=$(cat "$stdout_file")
  HOOK_STDERR=$(cat "$stderr_file")
  HOOK_RC=$rc
  rm -f "$stdout_file" "$stderr_file"
}

# run_isolated <config> <command> [bg] — exercise hook with a temp config.
# $config is written verbatim to the temp .always-allow file. HOME is also
# pointed at a fresh empty dir so the real user config can't leak in.
run_isolated() {
  local config="$1" command="$2" bg="${3:-false}"
  local fixture_dir home_dir stdout_file stderr_file rc input
  fixture_dir=$(mktemp -d)
  home_dir=$(mktemp -d)
  mkdir -p "$home_dir/.claude"
  printf '%s\n' "$config" > "$fixture_dir/.always-allow"
  stdout_file=$(mktemp); stderr_file=$(mktemp)
  input=$(make_input "$command" "$bg")
  if echo "$input" | HOME="$home_dir" CLAUDE_PROJECT_DIR="$fixture_dir" \
      bash "$HOOK" >"$stdout_file" 2>"$stderr_file"; then
    rc=0
  else
    rc=$?
  fi
  HOOK_STDOUT=$(cat "$stdout_file")
  HOOK_STDERR=$(cat "$stderr_file")
  HOOK_RC=$rc
  rm -rf "$fixture_dir" "$home_dir"
  rm -f "$stdout_file" "$stderr_file"
}

assert_allow() {
  local desc="$1"
  if [ "$HOOK_RC" -eq 0 ] && [ "$HOOK_STDOUT" = '{"decision": "allow"}' ] && [ -z "$HOOK_STDERR" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected auto-allow; rc=$HOOK_RC stdout='$HOOK_STDOUT' stderr='$HOOK_STDERR')"
  fi
}

assert_pass_through() {
  local desc="$1"
  if [ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected silent pass-through; rc=$HOOK_RC stdout='$HOOK_STDOUT' stderr='$HOOK_STDERR')"
  fi
}

echo "=== always-allow tests ==="

# --- Tool / input gating --------------------------------------------------
echo
echo "--- Tool / input gating ---"
RAW=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}' \
  | bash "$HOOK" 2>&1) || true
if [ -z "$RAW" ]; then
  PASS=$((PASS + 1)); echo "  PASS: Non-Bash tool passes through silently"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: Non-Bash tool ($RAW)"
fi

RAW=$(echo '{"tool_name":"Bash","tool_input":{"command":""}}' \
  | bash "$HOOK" 2>&1) || true
if [ -z "$RAW" ]; then
  PASS=$((PASS + 1)); echo "  PASS: Empty command passes through silently"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: Empty command ($RAW)"
fi

# --- Integration with project .always-allow -------------------------------
echo
echo "--- Integration with project .always-allow ---"
run_hook "scripts/build.sh";              assert_allow        "scripts/build.sh ([allow])"
run_hook "scripts/build-frontend.sh";     assert_allow        "scripts/build-frontend.sh (alnum suffix)"
run_hook "scripts/build/frontend.sh";     assert_pass_through "scripts/build/frontend.sh (slash inside)"
run_hook "woo/scripts/build-frontend.sh"; assert_pass_through "woo/scripts/build-frontend.sh (prefix anchor)"
run_hook "scripts/inspect.sh woo yay";    assert_allow        "scripts/inspect.sh + args"
run_hook "scripts/run.sh";                assert_allow        "scripts/run.sh (fg via [background])"
run_hook "scripts/run.sh"          true;  assert_allow        "scripts/run.sh in bg (via [background])"
run_hook "scripts/build.sh"        true;  assert_pass_through "scripts/build.sh in bg (only in [allow])"
run_hook "scripts/install-deps.sh";       assert_pass_through "scripts/install-deps.sh (no rule)"

# --- Multi-command guard --------------------------------------------------
echo
echo "--- Multi-command guard ---"
run_hook "scripts/build.sh && echo done";    assert_pass_through "AND chain"
run_hook "scripts/build.sh | tee build.log"; assert_pass_through "pipe"
run_hook "scripts/build.sh; ls";             assert_pass_through "semicolon"
run_hook "scripts/build.sh || echo failed";  assert_pass_through "OR chain"
run_hook $'scripts/build.sh\necho done';     assert_pass_through "newline"
run_hook $'scripts/inspect.sh foo\nrm -rf /'; assert_pass_through "newline with dangerous suffix"
run_hook "scripts/run.sh && ls" true;        assert_pass_through "multi-command rejected even via [background]"

# --- Section parsing (isolated) ------------------------------------------
echo
echo "--- Section parsing (isolated) ---"

# Backward compat: untagged patterns at the top of the file route to [allow].
run_isolated $'^foo$' "foo";                 assert_allow        "untagged pattern → default [allow] (fg)"
run_isolated $'^foo$' "foo" true;            assert_pass_through "untagged pattern not eligible in bg"
run_isolated $'^foo$' "bar";                 assert_pass_through "non-matching command in [allow]"

# Explicit [allow] header.
run_isolated $'[allow]\n^foo$' "foo";        assert_allow        "[allow] explicit header (fg)"
run_isolated $'[allow]\n^foo$' "foo" true;   assert_pass_through "[allow] explicit header not in bg"

# [background] in both modes.
run_isolated $'[background]\n^foo$' "foo";       assert_allow "[background] matches fg too"
run_isolated $'[background]\n^foo$' "foo" true;  assert_allow "[background] matches bg"
run_isolated $'[background]\n^foo$' "bar" true;  assert_pass_through "[background] non-matching command in bg"

# [bg] alias for [background].
run_isolated $'[bg]\n^foo$' "foo" true;          assert_allow "[bg] alias matches bg"
run_isolated $'[bg]\n^foo$' "foo";               assert_allow "[bg] alias matches fg"

# Section switching: allow → background → allow.
SWITCH=$'[allow]\n^one$\n[background]\n^two$\n[allow]\n^three$'
run_isolated "$SWITCH" "one";        assert_allow        "switch: one in [allow] (fg)"
run_isolated "$SWITCH" "one"   true; assert_pass_through "switch: one not eligible in bg"
run_isolated "$SWITCH" "two";        assert_allow        "switch: two in [background] (fg)"
run_isolated "$SWITCH" "two"   true; assert_allow        "switch: two in [background] (bg)"
run_isolated "$SWITCH" "three";      assert_allow        "switch: three back in [allow] (fg)"
run_isolated "$SWITCH" "three" true; assert_pass_through "switch: three back in [allow], not bg"

# Same pattern in both sections — bg should still allow via [background].
DUP=$'[allow]\n^foo$\n[background]\n^foo$'
run_isolated "$DUP" "foo";      assert_allow "dup pattern: [allow]+[background] in fg"
run_isolated "$DUP" "foo" true; assert_allow "dup pattern: [background] still wins in bg"

# Unknown section silently skips its patterns.
run_isolated $'[mystery]\n^foo$' "foo";          assert_pass_through "[mystery] pattern not routed"
run_isolated $'[mystery]\n^foo$\n[allow]\n^foo$' "foo"; \
  assert_allow "later [allow] still routed after unknown section"

# Sparse / degenerate files.
run_isolated ""               "foo";          assert_pass_through "empty config file"
run_isolated $'# only a comment' "foo";       assert_pass_through "comment-only config"
run_isolated $'[allow]\n[background]' "foo";  assert_pass_through "header-only config (no patterns)"

# Whitespace / comments between header and patterns are fine.
run_isolated $'[background]\n\n# CanvasHost\n\n^foo$' "foo" true; \
  assert_allow "blank lines and comments between header and pattern"

# Trailing comment on a pattern line is stripped before regex compile.
run_isolated $'[allow]\n^foo$  # the foo pattern' "foo"; \
  assert_allow "trailing # comment stripped from pattern line"

# --- Disabled via env var -------------------------------------------------
echo
echo "--- Disabled via env var ---"
RAW=$(echo '{"tool_name":"Bash","tool_input":{"command":"scripts/build.sh"}}' \
  | ALWAYS_ALLOW_DISABLED=1 bash "$HOOK" 2>&1) || true
if [ -z "$RAW" ]; then
  PASS=$((PASS + 1)); echo "  PASS: ALWAYS_ALLOW_DISABLED=1 short-circuits before matching"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ALWAYS_ALLOW_DISABLED ($RAW)"
fi

echo
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "Total: $((PASS + FAIL)) tests"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
