#!/bin/bash
# Tests for read-guard hook
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/hook.sh"
PASS=0
FAIL=0

run_hook() {
  local command="$1"
  local stdout_file stderr_file rc
  stdout_file=$(mktemp); stderr_file=$(mktemp)
  local input
  input=$(jq -cn --arg cmd "$command" '{"tool_name":"Bash","tool_input":{"command":$cmd}}')
  if echo "$input" | bash "$HOOK" >"$stdout_file" 2>"$stderr_file"; then rc=0; else rc=$?; fi
  HOOK_STDOUT=$(cat "$stdout_file"); HOOK_STDERR=$(cat "$stderr_file"); HOOK_RC=$rc
  rm -f "$stdout_file" "$stderr_file"
}

assert_blocked() {
  local desc="$1" command="$2"
  run_hook "$command"
  if [ "$HOOK_RC" -eq 2 ] && [ -z "$HOOK_STDOUT" ] && echo "$HOOK_STDERR" | grep -q 'read-guard:'; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (rc=$HOOK_RC stdout='$HOOK_STDOUT' stderr='$HOOK_STDERR')"
  fi
}

assert_allowed() {
  local desc="$1" command="$2"
  run_hook "$command"
  if [ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (rc=$HOOK_RC stdout='$HOOK_STDOUT' stderr='$HOOK_STDERR')"
  fi
}

echo "=== read-guard tests ==="

echo ""
echo "--- Non-Bash tools pass through ---"
RESULT=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}' | bash "$HOOK" 2>/dev/null) || true
if [ -z "$RESULT" ]; then
  PASS=$((PASS + 1)); echo "  PASS: Read tool passes through"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: Read tool should pass through"
fi

echo ""
echo "--- cat ---"
assert_blocked "cat file"              "cat README.md"
assert_blocked "cat -n file"           "cat -n README.md"
assert_blocked "cat in pipeline"       "cat README.md | grep foo"
assert_allowed "bare cat (stdin)"      "cat"
assert_allowed "cat redirect (stdin)"  "cat > output.txt"

echo ""
echo "--- head / tail ---"
assert_blocked "head file"        "head README.md"
assert_blocked "head -n file"     "head -n 20 README.md"
assert_blocked "tail file"        "tail README.md"
assert_blocked "tail -f file"     "tail -f app.log"
assert_blocked "tail -n file"     "tail -n 50 README.md"
assert_allowed "head in pipeline" "ls -la | head -5"
assert_allowed "tail in pipeline" "ls -la | tail -10"

echo ""
echo "--- less / more / bat / strings (new) ---"
assert_blocked "less file"          "less README.md"
assert_blocked "more file"          "more README.md"
assert_blocked "bat file"           "bat src/main.rs"
assert_blocked "bat with flags"     "bat -n src/main.rs"
assert_blocked "strings binary"     "strings ./build/app"
assert_blocked "strings with flag"  "strings -n 8 ./build/app"

echo ""
echo "--- sed ---"
assert_blocked "sed without -i (read)"    "sed 's/foo/bar/' config.txt"
assert_blocked "sed -n read mode"         "sed -n '1,10p' config.txt"
assert_blocked "sed -e read mode"         "sed -e 's/a/b/' file.txt"
assert_allowed "sed -i in-place (write)"  "sed -i 's/foo/bar/' config.txt"
assert_allowed "sed -i.bak in-place"      "sed -i.bak 's/foo/bar/' config.txt"
assert_allowed "sed in pipeline"          "ls -la | sed 's/foo/bar/'"

echo ""
echo "--- awk ---"
assert_blocked "awk on file"          "awk '{print}' data.csv"
assert_blocked "awk -F on file"       "awk -F: '{print \$1}' /etc/passwd"
assert_blocked "awk pattern on file"  "awk '/error/{print}' app.log"
assert_allowed "awk in pipeline"      "ls -la | awk '{print \$1}'"

echo ""
echo "--- sort / tac / nl / od / xxd / hexdump ---"
assert_blocked "sort file"            "sort data.csv"
assert_blocked "sort with flag"       "sort -k2 data.csv"
assert_blocked "tac file"             "tac README.md"
assert_blocked "nl file"              "nl README.md"
assert_blocked "od file"              "od -x binary.bin"
assert_blocked "xxd file"             "xxd binary.bin"
assert_blocked "hexdump file"         "hexdump -C binary.bin"
assert_allowed "sort stdin (bare)"    "sort"
assert_allowed "sort in pipeline"     "ls -la | sort -k5"

echo ""
echo "--- grep / rg / ag / cut ---"
assert_blocked "grep file"            "grep pattern file.txt"
assert_blocked "grep -r dir"          "grep -r pattern src/"
assert_blocked "grep -n file"         "grep -n TODO file.txt"
assert_blocked "egrep file"           "egrep 'foo|bar' file.txt"
assert_blocked "fgrep file"           "fgrep literal file.txt"
assert_blocked "rg pattern"           "rg pattern src/"
assert_blocked "ag pattern"           "ag pattern src/"
assert_blocked "cut file"             "cut -f1 data.csv"
assert_blocked "grep after &&"        "ls && grep foo file.txt"
assert_blocked "grep after semicolon" "ls; grep foo file.txt"
assert_blocked "grep after ||"        "ls || grep foo file.txt"
assert_allowed "grep as pipe filter"  "ls | grep foo"
assert_allowed "grep pipe chain"      "ls -la | grep '.txt'"
assert_allowed "cut as pipe filter"   "ls -la | cut -d' ' -f1"
assert_allowed "rg as pipe filter"    "ps aux | rg ERROR"

echo ""
echo "--- Output redirected to file (should be allowed) ---"
assert_allowed "cat to file"                   "cat README.md > scratch/out.txt"
assert_allowed "cat append to file"            "cat README.md >> scratch/out.txt"
assert_allowed "cat pipeline to file"          "cat README.md | grep foo > scratch/out.txt"
assert_allowed "head to file"                  "head -n 20 README.md > scratch/out.txt"
assert_allowed "tail to file"                  "tail -n 50 README.md > scratch/out.txt"
assert_allowed "sed to file"                   "sed 's/foo/bar/' config.txt > scratch/out.txt"
assert_allowed "awk to file"                   "awk '{print}' data.csv > scratch/out.txt"
assert_allowed "bat to file"                   "bat src/main.rs > scratch/out.txt"
assert_allowed "strings to file"               "strings ./build/app > scratch/out.txt"
assert_allowed "grep to file"                  "grep pattern file.txt > scratch/out.txt"
assert_allowed "sort to file"                  "sort data.csv > scratch/out.txt"
assert_blocked "cat pipeline no redirect"      "cat README.md | grep foo"
assert_blocked "stderr-only redirect blocked"  "cat README.md 2> err.txt"

echo ""
echo "--- Config-driven directory exclusions (default.read-guard) ---"
# Stash any existing config file so tests are deterministic.
CONFIG_FILE="$SCRIPT_DIR/default.read-guard"
CONFIG_BACKUP=""
if [ -f "$CONFIG_FILE" ]; then
  CONFIG_BACKUP=$(mktemp)
  cp "$CONFIG_FILE" "$CONFIG_BACKUP"
fi
trap '[ -n "$CONFIG_BACKUP" ] && mv "$CONFIG_BACKUP" "$CONFIG_FILE" || rm -f "$CONFIG_FILE"' EXIT

cat > "$CONFIG_FILE" <<'EOF'
# test config
scratch/
build/output/
EOF

assert_allowed "cat in excluded dir"               "cat scratch/foo.txt"
assert_allowed "head in excluded dir"              "head -n 5 scratch/foo.txt"
assert_allowed "grep in excluded dir"              "grep TODO scratch/notes.txt"
assert_allowed "sed in excluded dir"               "sed -n '1,10p' scratch/foo.txt"
assert_allowed "awk in excluded dir"               "awk '{print}' scratch/data.csv"
assert_allowed "cat in nested excluded path"       "cat scratch/sub/dir/foo.txt"
assert_allowed "cat in excluded absolute path"     "cat /home/user/proj/scratch/foo.txt"
assert_allowed "quoted path in excluded dir"       "cat \"scratch/foo bar.txt\""
assert_allowed "nested excluded dir"               "cat build/output/log.txt"
assert_blocked "cat outside excluded dir"          "cat README.md"
assert_blocked "similar prefix not excluded"       "cat scratchpad/foo.txt"
assert_blocked "partial nested path not excluded"  "cat build/source/foo.txt"

# Remove config — exclusions should no longer apply.
rm -f "$CONFIG_FILE"
assert_blocked "no config: scratch is blocked"     "cat scratch/foo.txt"

# Restore config (or leave absent) for subsequent steps.
if [ -n "$CONFIG_BACKUP" ]; then
  mv "$CONFIG_BACKUP" "$CONFIG_FILE"
  CONFIG_BACKUP=""
fi
trap - EXIT

echo ""
echo "--- Disabled via env ---"
STDOUT_FILE=$(mktemp)
jq -cn --arg cmd "cat README.md" '{"tool_name":"Bash","tool_input":{"command":$cmd}}' \
  | env READ_GUARD_DISABLED=1 bash "$HOOK" >"$STDOUT_FILE" 2>/dev/null || true
DISABLED_RESULT=$(cat "$STDOUT_FILE"); rm -f "$STDOUT_FILE"
if [ -z "$DISABLED_RESULT" ]; then
  PASS=$((PASS + 1)); echo "  PASS: READ_GUARD_DISABLED=1 bypasses guard"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: READ_GUARD_DISABLED=1 should bypass guard"
fi

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "Total: $((PASS + FAIL)) tests"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
