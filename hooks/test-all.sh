#!/usr/bin/env bash
# Run every hook's test suite in sequence and report a combined result.
#
# Exit codes:
#   0 — every suite passed
#   1 — one or more suites failed
#
# Usage:
#   bash hooks/test-all.sh           # full run, summary at the end
#   bash hooks/test-all.sh -v        # also stream each suite's stdout
#
# A suite is whatever `test.sh` lives inside a hook directory. Jailbreak
# probes (`test-jailbreak.sh`) are NOT invoked here because each hook's
# own test.sh already chains into them — running them again would
# double-count.

set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"

VERBOSE=0
case "${1:-}" in
  -v|--verbose) VERBOSE=1 ;;
  "") ;;
  *) echo "usage: $0 [-v]" >&2; exit 2 ;;
esac

# Discover suites: every hook subdir that has a test.sh.
SUITES=()
for hook in "$HOOKS_DIR"/*/; do
  test_path="$hook/test.sh"
  if [ -f "$test_path" ]; then
    SUITES+=("${hook%/}")
  fi
done

if [ "${#SUITES[@]}" -eq 0 ]; then
  echo "test-all: no test.sh found under any hook directory" >&2
  exit 1
fi

# ANSI colour if stdout is a tty.
if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_DIM=""; C_RESET=""
fi

declare -a FAILED_SUITES=()
TOTAL_SUITES="${#SUITES[@]}"
PASS_SUITES=0
START_ALL=$(date +%s)

for suite_dir in "${SUITES[@]}"; do
  hook_name="$(basename "$suite_dir")"
  test_path="$suite_dir/test.sh"
  log_file=$(mktemp)
  start=$(date +%s)

  printf '%s%-22s%s ' "$C_DIM" "$hook_name" "$C_RESET"

  rc=0
  bash "$test_path" >"$log_file" 2>&1 || rc=$?
  elapsed=$(( $(date +%s) - start ))

  if [ "$rc" -eq 0 ]; then
    PASS_SUITES=$((PASS_SUITES + 1))
    printf '%s PASS %s  %ds\n' "$C_GREEN" "$C_RESET" "$elapsed"
    [ "$VERBOSE" -eq 1 ] && { sed 's/^/    /' "$log_file"; echo; }
  else
    FAILED_SUITES+=("$hook_name")
    printf '%s FAIL %s  %ds  rc=%d\n' "$C_RED" "$C_RESET" "$elapsed" "$rc"
    # Always show output on failure, even without -v.
    sed 's/^/    /' "$log_file"
    echo
  fi

  rm -f "$log_file"
done

ELAPSED_ALL=$(( $(date +%s) - START_ALL ))

echo
echo "================================"
if [ "${#FAILED_SUITES[@]}" -eq 0 ]; then
  printf '%sAll %d hook suites passed%s  (%ds)\n' "$C_GREEN" "$TOTAL_SUITES" "$C_RESET" "$ELAPSED_ALL"
  exit 0
else
  printf '%s%d/%d suites failed%s  (%ds):\n' "$C_RED" "${#FAILED_SUITES[@]}" "$TOTAL_SUITES" "$C_RESET" "$ELAPSED_ALL"
  for s in "${FAILED_SUITES[@]}"; do
    printf '  - %s\n' "$s"
  done
  exit 1
fi
