#!/bin/bash
# Tests for always-allow hook
#
# Every test uses run_isolated so the suite is independent of the caller's
# CLAUDE_PROJECT_DIR / HOME / shipped default.always-allow. The fixture
# helper creates a temp dir per case, points all three config paths at it
# via env-var overrides (ALWAYS_ALLOW_HOOK_DIR for default, HOME for user,
# CLAUDE_PROJECT_DIR for project), then runs the hook.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/hook.sh"
PASS=0
FAIL=0

# Pin CLAUDE_PROJECT_DIR to a sentinel that doesn't resolve to anything real,
# so a forgetful test that uses raw $HOOK can't pick up a stray .always-allow.
export CLAUDE_PROJECT_DIR="/nonexistent-test-project"

# --- Helpers --------------------------------------------------------------

# Build the JSON input the hook reads from stdin.
make_input() {
  jq -cn --arg cmd "$1" --argjson bg "$2" \
    '{"tool_name":"Bash","tool_input":{"command":$cmd,"run_in_background":$bg}}'
}

# Build a Read-tool input (for the non-Bash pass-through test).
make_read_input() {
  jq -cn --arg path "$1" '{"tool_name":"Read","tool_input":{"file_path":$path}}'
}

# Run with a fully isolated fixture.
#
#   run_isolated <project-config> <command> [bg] [user-config] [default-config]
#
# project-config:  contents of $CLAUDE_PROJECT_DIR/.always-allow
# command:         the Bash command to feed the hook
# bg:              true|false (default false)
# user-config:     contents of $HOME/.claude/.always-allow (empty by default)
# default-config:  contents of $HOOK_DIR/default.always-allow (empty by default)
run_isolated() {
  local project_cfg="$1" command="$2" bg="${3:-false}"
  local user_cfg="${4:-}" default_cfg="${5:-}"
  local proj_dir home_dir hook_dir stdout_file stderr_file rc input

  proj_dir=$(mktemp -d)
  home_dir=$(mktemp -d)
  hook_dir=$(mktemp -d)
  mkdir -p "$home_dir/.claude"
  printf '%s' "$project_cfg"  > "$proj_dir/.always-allow"
  printf '%s' "$user_cfg"     > "$home_dir/.claude/.always-allow"
  printf '%s' "$default_cfg"  > "$hook_dir/default.always-allow"

  stdout_file=$(mktemp); stderr_file=$(mktemp)
  input=$(make_input "$command" "$bg")
  if echo "$input" \
      | HOME="$home_dir" \
        CLAUDE_PROJECT_DIR="$proj_dir" \
        ALWAYS_ALLOW_HOOK_DIR="$hook_dir" \
        bash "$HOOK" >"$stdout_file" 2>"$stderr_file"; then
    rc=0
  else
    rc=$?
  fi
  HOOK_STDOUT=$(cat "$stdout_file")
  HOOK_STDERR=$(cat "$stderr_file")
  HOOK_RC=$rc
  rm -rf "$proj_dir" "$home_dir" "$hook_dir"
  rm -f "$stdout_file" "$stderr_file"
}

# Variant for raw-JSON input (Read-tool case, malformed JSON, etc.).
run_raw() {
  local input="$1"
  local proj_dir home_dir hook_dir stdout_file stderr_file rc
  proj_dir=$(mktemp -d); home_dir=$(mktemp -d); hook_dir=$(mktemp -d)
  mkdir -p "$home_dir/.claude"

  stdout_file=$(mktemp); stderr_file=$(mktemp)
  if printf '%s' "$input" \
      | HOME="$home_dir" \
        CLAUDE_PROJECT_DIR="$proj_dir" \
        ALWAYS_ALLOW_HOOK_DIR="$hook_dir" \
        bash "$HOOK" >"$stdout_file" 2>"$stderr_file"; then
    rc=0
  else
    rc=$?
  fi
  HOOK_STDOUT=$(cat "$stdout_file")
  HOOK_STDERR=$(cat "$stderr_file")
  HOOK_RC=$rc
  rm -rf "$proj_dir" "$home_dir" "$hook_dir"
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

# Assert hook exits 0 with empty stdout, regardless of stderr.
assert_no_decision() {
  local desc="$1"
  if [ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_STDOUT" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected rc=0 + empty stdout; got rc=$HOOK_RC stdout='$HOOK_STDOUT')"
  fi
}

# --- Tests start ----------------------------------------------------------

echo "=== always-allow tests ==="

# --- Tool / input gating --------------------------------------------------
echo
echo "--- Tool / input gating ---"

run_raw "$(make_read_input /etc/passwd)"
assert_pass_through "Non-Bash tool (Read) passes through silently"

run_raw '{"tool_name":"Bash","tool_input":{"command":""}}'
assert_pass_through "Empty command passes through"

run_raw '{"tool_name":"Bash","tool_input":{}}'
assert_pass_through "Missing command key passes through"

run_raw '{"tool_name":"Bash"}'
assert_pass_through "Missing tool_input passes through"

run_raw '{}'
assert_pass_through "Empty JSON object passes through"

# --- Foreground vs background behaviour ----------------------------------
echo
echo "--- Foreground vs background ---"

run_isolated $'[allow]\n^foo$' "foo"
assert_allow "[allow] pattern matches foreground"

run_isolated $'[allow]\n^foo$' "foo" true
assert_pass_through "[allow] pattern does NOT match background"

run_isolated $'[allow]\n^foo$' "bar"
assert_pass_through "non-matching command in [allow] section"

run_isolated $'[background]\n^foo$' "foo"
assert_allow "[background] pattern matches foreground too"

run_isolated $'[background]\n^foo$' "foo" true
assert_allow "[background] pattern matches background"

run_isolated $'[background]\n^foo$' "bar" true
assert_pass_through "non-matching command in [background] section"

run_isolated $'[bg]\n^foo$' "foo" true
assert_allow "[bg] alias for [background] works in bg"

run_isolated $'[bg]\n^foo$' "foo"
assert_allow "[bg] alias works in fg"

# --- Multi-command guard --------------------------------------------------
echo
echo "--- Multi-command guard ---"
ALLOW_FOO=$'[background]\n^foo'
run_isolated "$ALLOW_FOO" "foo && bar"
assert_pass_through "AND chain rejected even with [background] match"
run_isolated "$ALLOW_FOO" "foo | tee log"
assert_pass_through "pipe rejected"
run_isolated "$ALLOW_FOO" "foo; bar"
assert_pass_through "semicolon rejected"
run_isolated "$ALLOW_FOO" "foo || bar"
assert_pass_through "OR chain rejected"
run_isolated "$ALLOW_FOO" $'foo\nbar'
assert_pass_through "newline rejected"
run_isolated "$ALLOW_FOO" $'foo arg\nrm -rf /'
assert_pass_through "newline with dangerous suffix rejected"
run_isolated "$ALLOW_FOO" "foo && bar" true
assert_pass_through "multi-command rejected even with [background] match in bg"

# --- Section parsing ------------------------------------------------------
echo
echo "--- Section parsing ---"

# Backward compatibility: untagged patterns route to [allow].
run_isolated $'^foo$' "foo"
assert_allow "untagged pattern at top → default [allow] in fg"

run_isolated $'^foo$' "foo" true
assert_pass_through "untagged pattern not eligible in bg"

# Section switching: allow → background → allow.
SWITCH=$'[allow]\n^one$\n[background]\n^two$\n[allow]\n^three$'
run_isolated "$SWITCH" "one"
assert_allow        "switch: one in [allow] (fg)"
run_isolated "$SWITCH" "one" true
assert_pass_through "switch: one not eligible in bg"
run_isolated "$SWITCH" "two"
assert_allow        "switch: two in [background] (fg)"
run_isolated "$SWITCH" "two" true
assert_allow        "switch: two in [background] (bg)"
run_isolated "$SWITCH" "three"
assert_allow        "switch: three back in [allow] (fg)"
run_isolated "$SWITCH" "three" true
assert_pass_through "switch: three back in [allow], not bg"

# Duplicate pattern in both sections — [background] still wins in bg.
DUP=$'[allow]\n^foo$\n[background]\n^foo$'
run_isolated "$DUP" "foo"
assert_allow "dup pattern in [allow]+[background], fg"
run_isolated "$DUP" "foo" true
assert_allow "dup pattern in [allow]+[background], bg"

# Unknown section silently skips its patterns.
run_isolated $'[mystery]\n^foo$' "foo"
assert_pass_through "[mystery] section's pattern not routed"

run_isolated $'[mystery]\n^foo$\n[allow]\n^foo$' "foo"
assert_allow "later [allow] still routed after unknown section"

# Sparse / degenerate files.
run_isolated "" "foo"
assert_pass_through "empty project config"

run_isolated $'# only a comment' "foo"
assert_pass_through "comment-only project config"

run_isolated $'[allow]\n[background]' "foo"
assert_pass_through "header-only config (no patterns)"

# Whitespace / comments between header and patterns.
run_isolated $'[background]\n\n# CanvasHost\n\n^foo$' "foo" true
assert_allow "blank lines + comments between header and pattern"

# Trailing comment on pattern line stripped before regex compile.
run_isolated $'[allow]\n^foo$  # the foo pattern' "foo"
assert_allow "trailing comment stripped from pattern line"

# Section header case-sensitivity. Strict `^\[([a-z]+)\]$` rejects upper-
# case. To demonstrate this we need a case where the rejected header would
# have changed the section context — otherwise the test passes for the
# wrong reason. Use uppercase `[BACKGROUND]` followed by a pattern: if the
# header were honoured the pattern would be in [background] and eligible
# in bg; if rejected, the pattern stays in implicit [allow] and is fg-only.
run_isolated $'[BACKGROUND]\n^foo$' "foo" true
assert_pass_through "uppercase [BACKGROUND] header rejected — pattern stays in implicit [allow], not eligible in bg"

run_isolated $'[BACKGROUND]\n^foo$' "foo"
assert_allow "rejected [BACKGROUND] still leaves pattern in implicit [allow] (matches in fg)"

# --- Layered configs (default + user + project) ---------------------------
echo
echo "--- Layered configs ---"

# Pattern only in shipped default.
run_isolated "" "make build" false "" $'[allow]\n^make build$'
assert_allow "default.always-allow [allow] pattern matches"

# Pattern only in $HOME/.claude/.always-allow.
run_isolated "" "user-script" false $'[allow]\n^user-script$' ""
assert_allow "user-level .always-allow [allow] pattern matches"

# Pattern only in project .always-allow.
run_isolated $'[allow]\n^project-script$' "project-script"
assert_allow "project-level .always-allow [allow] pattern matches"

# All three layers active: default has fg pattern, user has bg pattern,
# project has another fg pattern. Each command exercises one layer.
run_isolated \
  $'[allow]\n^proj$' \
  "deflt" \
  false \
  $'[background]\n^user-bg$' \
  $'[allow]\n^deflt$'
assert_allow "three layers loaded: default match in fg"

run_isolated \
  $'[allow]\n^proj$' \
  "user-bg" \
  true \
  $'[background]\n^user-bg$' \
  $'[allow]\n^deflt$'
assert_allow "three layers loaded: user [background] match in bg"

run_isolated \
  $'[allow]\n^proj$' \
  "proj" \
  false \
  $'[background]\n^user-bg$' \
  $'[allow]\n^deflt$'
assert_allow "three layers loaded: project match in fg"

run_isolated \
  $'[allow]\n^proj$' \
  "deflt" \
  true \
  $'[background]\n^user-bg$' \
  $'[allow]\n^deflt$'
assert_pass_through "three layers loaded: default [allow] not eligible in bg"

# Section context resets between files: section in default does not leak
# into the user file.
run_isolated \
  "" \
  "bar" \
  true \
  $'^bar$' \
  $'[background]\n^foo$'
assert_pass_through "section context does not leak across files (user file starts fresh in [allow])"

# But within a file, the first untagged patterns go to [allow] until a
# header switches sections.
run_isolated $'^foo$\n[background]\n^bar$' "foo"
assert_allow "untagged pattern routes to [allow] (fg) before any header"

run_isolated $'^foo$\n[background]\n^bar$' "foo" true
assert_pass_through "untagged pattern not eligible in bg"

run_isolated $'^foo$\n[background]\n^bar$' "bar" true
assert_allow "header-switched [background] pattern eligible in bg"

# --- Pattern edge cases ---------------------------------------------------
echo
echo "--- Pattern edge cases ---"

# A pattern line consisting only of a bracketed lowercase-alpha token is
# mis-parsed as a section header. The user's intended ERE pattern (a
# single-char class `[xyz]`) is silently turned into "switch context to
# section xyz", which has no matchable patterns, so the command matches
# nothing. Pins the current behaviour for the HARDENING.md entry.
run_isolated $'[allow]\n[xyz]' "x"
assert_pass_through "bare '[xyz]' pattern mis-parsed as section header (HARDENING)"

# Adjacent: a pattern that starts with a bracket but has trailing text is
# NOT a section-header collision, because the header regex anchors `]$`.
# The pattern is loaded normally and matches as expected.
run_isolated $'[allow]\n[xyz]foo' "xfoo"
assert_allow "'[xyz]foo' pattern loaded as ERE (header regex requires bracket-anchored ']')"

# Empty section (no patterns under [allow]).
run_isolated $'[allow]' "anything"
assert_pass_through "empty section has no matchable patterns"

# Pattern with regex metacharacters (POSIX ERE).
run_isolated $'[allow]\n^foo\\.[0-9]+$' "foo.42"
assert_allow "ERE metacharacters in pattern (char class + quantifier)"

run_isolated $'[allow]\n^foo\\.[0-9]+$' "foo.bar"
assert_pass_through "non-matching ERE pattern"

# Multiple patterns in same section — any one match wins.
MANY=$'[allow]\n^one$\n^two$\n^three$'
run_isolated "$MANY" "one";   assert_allow        "multiple patterns: one matches"
run_isolated "$MANY" "two";   assert_allow        "multiple patterns: two matches"
run_isolated "$MANY" "three"; assert_allow        "multiple patterns: three matches"
run_isolated "$MANY" "four";  assert_pass_through "multiple patterns: four does not match"

# --- Env-var knobs --------------------------------------------------------
echo
echo "--- Env-var knobs ---"

# ALWAYS_ALLOW_DISABLED short-circuits before any config or matching.
RAW_INPUT=$(make_input "anything" false)
RAW=$(echo "$RAW_INPUT" | ALWAYS_ALLOW_DISABLED=1 bash "$HOOK" 2>&1) || true
if [ -z "$RAW" ]; then
  PASS=$((PASS + 1)); echo "  PASS: ALWAYS_ALLOW_DISABLED=1 short-circuits, no output"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ALWAYS_ALLOW_DISABLED=1 should emit nothing (got: $RAW)"
fi

# ALWAYS_ALLOW_DISABLED=0 leaves the hook enabled.
DIS_ZERO=$(echo "$RAW_INPUT" | ALWAYS_ALLOW_DISABLED=0 bash "$HOOK" 2>&1) || true
if [ -z "$DIS_ZERO" ]; then
  PASS=$((PASS + 1)); echo "  PASS: ALWAYS_ALLOW_DISABLED=0 leaves hook enabled (pass-through, no rule)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ALWAYS_ALLOW_DISABLED=0 ($DIS_ZERO)"
fi

# ALWAYS_ALLOW_HOOK_DIR override: point at a fixture dir, drop a default
# config there, verify it loads. (run_isolated already exercises this for
# every other test — this case just makes the env-var override explicit.)
TMP_HOOK_DIR=$(mktemp -d)
printf '%s' $'[allow]\n^override-test$' > "$TMP_HOOK_DIR/default.always-allow"
RESULT=$(echo "$(make_input "override-test" false)" \
  | ALWAYS_ALLOW_HOOK_DIR="$TMP_HOOK_DIR" \
    HOME="$(mktemp -d)" \
    CLAUDE_PROJECT_DIR="$(mktemp -d)" \
    bash "$HOOK" 2>&1) || true
if [ "$RESULT" = '{"decision": "allow"}' ]; then
  PASS=$((PASS + 1)); echo "  PASS: ALWAYS_ALLOW_HOOK_DIR override loads custom default"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ALWAYS_ALLOW_HOOK_DIR override (got: $RESULT)"
fi
rm -rf "$TMP_HOOK_DIR"

# ALWAYS_ALLOW_LOG=1 writes diagnostics to stderr without changing the
# decision.
LOG_PROJ=$(mktemp -d)
printf '%s' $'[allow]\n^logme$' > "$LOG_PROJ/.always-allow"
LOG_RESULT_FILE=$(mktemp); LOG_STDERR=$(mktemp)
echo "$(make_input "logme" false)" \
  | ALWAYS_ALLOW_LOG=1 \
    HOME="$(mktemp -d)" \
    CLAUDE_PROJECT_DIR="$LOG_PROJ" \
    ALWAYS_ALLOW_HOOK_DIR="$(mktemp -d)" \
    bash "$HOOK" >"$LOG_RESULT_FILE" 2>"$LOG_STDERR" || true
LOG_STDOUT=$(cat "$LOG_RESULT_FILE")
LOG_STDERR_C=$(cat "$LOG_STDERR")
if [ "$LOG_STDOUT" = '{"decision": "allow"}' ] && [[ "$LOG_STDERR_C" == *"[always-allow]"* ]]; then
  PASS=$((PASS + 1)); echo "  PASS: ALWAYS_ALLOW_LOG=1 writes diagnostics, decision unchanged"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ALWAYS_ALLOW_LOG=1 (stdout='$LOG_STDOUT' stderr='$LOG_STDERR_C')"
fi
rm -rf "$LOG_PROJ"; rm -f "$LOG_RESULT_FILE" "$LOG_STDERR"

# --- Real project patterns (sanity check) ---------------------------------
# These mirror what the project's own .always-allow contains, but use the
# isolated fixture so they're independent of the caller's directory.
echo
echo "--- Real project patterns (isolated) ---"
PROJ_REAL=$'[allow]
^(bash )?scripts/build[[:alnum:]_-]*\\.sh
^(bash )?scripts/headless-chrome\\.sh$
^(bash )?scripts/inspect\\.sh.*
^(bash )?scripts/test\\.sh($|[[:space:]])

[background]
^(bash )?scripts/run\\.sh'

run_isolated "$PROJ_REAL" "scripts/build.sh"
assert_allow "scripts/build.sh ([allow])"
run_isolated "$PROJ_REAL" "bash scripts/build.sh"
assert_allow "bash scripts/build.sh ([allow])"
run_isolated "$PROJ_REAL" "scripts/build-frontend.sh"
assert_allow "scripts/build-frontend.sh (alnum suffix)"
run_isolated "$PROJ_REAL" "scripts/build/frontend.sh"
assert_pass_through "scripts/build/frontend.sh (slash inside not allowed)"
run_isolated "$PROJ_REAL" "woo/scripts/build-frontend.sh"
assert_pass_through "woo/scripts/build-frontend.sh (prefix anchored)"
run_isolated "$PROJ_REAL" "scripts/inspect.sh woo yay"
assert_allow "scripts/inspect.sh + args"
run_isolated "$PROJ_REAL" "scripts/run.sh"
assert_allow "scripts/run.sh (fg via [background])"
run_isolated "$PROJ_REAL" "scripts/run.sh" true
assert_allow "scripts/run.sh in bg (via [background])"
run_isolated "$PROJ_REAL" "scripts/build.sh" true
assert_pass_through "scripts/build.sh in bg (only in [allow])"
run_isolated "$PROJ_REAL" "scripts/test.sh"
assert_allow "scripts/test.sh ([allow])"
run_isolated "$PROJ_REAL" "scripts/install-deps.sh"
assert_pass_through "scripts/install-deps.sh (no rule)"

echo
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "Total: $((PASS + FAIL)) tests"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
