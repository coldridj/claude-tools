#!/usr/bin/env bash
# Tests for session-scratch hook.
#
# Each test runs in its own temp project directory so concurrent runs cannot
# collide. The hook is invoked with stdin JSON and a controlled environment
# (PROJECT_DIR, optional SCRATCH_ROOT override, optional ENV_FILE).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/hook.sh"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ — $2}"; }

# Build the JSON input.
make_input() {
  local event="$1" sid="$2"
  case "$event,$sid" in
    ,)   echo '{}' ;;
    ,*)  jq -cn --arg sid "$sid" '{session_id:$sid}' ;;
    *,)  jq -cn --arg ev "$event"  '{hook_event_name:$ev}' ;;
    *,*) jq -cn --arg ev "$event" --arg sid "$sid" \
           '{hook_event_name:$ev, session_id:$sid}' ;;
  esac
}

# run_hook <event> <sid> [env KEY=VAL ...]
# Pipes JSON to the hook with the given env. Stores stdout/stderr/rc.
run_hook() {
  local event="$1" sid="$2"; shift 2
  local input out_f err_f rc
  input=$(make_input "$event" "$sid")
  out_f=$(mktemp); err_f=$(mktemp)
  if echo "$input" | env "$@" bash "$HOOK" >"$out_f" 2>"$err_f"; then
    rc=0
  else
    rc=$?
  fi
  HOOK_STDOUT=$(cat "$out_f"); HOOK_STDERR=$(cat "$err_f"); HOOK_RC=$rc
  rm -f "$out_f" "$err_f"
}

echo "=== session-scratch tests ==="

# --- SessionStart: per-session dir creation ---------------------------------
echo
echo "--- SessionStart: per-session dir creation ---"

PROJ=$(mktemp -d)
run_hook SessionStart "sid-001" "CLAUDE_PROJECT_DIR=$PROJ"
[ "$HOOK_RC" -eq 0 ] || fail "exit 0" "rc=$HOOK_RC stderr=$HOOK_STDERR"
[ "$HOOK_RC" -eq 0 ] && ok "SessionStart returns 0"
[ -d "$PROJ/.scratch/sid-001" ] && ok "SessionStart creates per-session dir" \
  || fail "SessionStart creates per-session dir" "missing $PROJ/.scratch/sid-001"
rm -rf "$PROJ"

# Re-running SessionStart with the same id is idempotent (no error).
PROJ=$(mktemp -d)
run_hook SessionStart "sid-002" "CLAUDE_PROJECT_DIR=$PROJ"
run_hook SessionStart "sid-002" "CLAUDE_PROJECT_DIR=$PROJ"
[ "$HOOK_RC" -eq 0 ] && [ -d "$PROJ/.scratch/sid-002" ] \
  && ok "SessionStart idempotent on repeat invocation" \
  || fail "SessionStart idempotent on repeat invocation" "rc=$HOOK_RC"
rm -rf "$PROJ"

# --- SessionStart: env-file export ------------------------------------------
echo
echo "--- SessionStart: env-file export ---"

PROJ=$(mktemp -d)
ENV_FILE="$PROJ/env.sh"
run_hook SessionStart "sid-100" \
  "CLAUDE_PROJECT_DIR=$PROJ" "CLAUDE_ENV_FILE=$ENV_FILE"
[ -f "$ENV_FILE" ] || { fail "env file created" "no $ENV_FILE"; rm -rf "$PROJ"; }
if [ -f "$ENV_FILE" ]; then
  CONTENT=$(cat "$ENV_FILE")
  case "$CONTENT" in
    *"CLAUDE_SESSION_ID=\"sid-100\""*) ok "env file exports CLAUDE_SESSION_ID" ;;
    *) fail "env file exports CLAUDE_SESSION_ID" "content=$CONTENT" ;;
  esac
  case "$CONTENT" in
    *"CLAUDE_SESSION_SCRATCH=\"$PROJ/.scratch/sid-100\""*) ok "env file exports CLAUDE_SESSION_SCRATCH" ;;
    *) fail "env file exports CLAUDE_SESSION_SCRATCH" "content=$CONTENT" ;;
  esac
fi
rm -rf "$PROJ"

# Env file appended to (not overwritten) when it already has content.
PROJ=$(mktemp -d)
ENV_FILE="$PROJ/env.sh"
echo "export EXISTING=preserve" > "$ENV_FILE"
run_hook SessionStart "sid-101" \
  "CLAUDE_PROJECT_DIR=$PROJ" "CLAUDE_ENV_FILE=$ENV_FILE"
CONTENT=$(cat "$ENV_FILE")
case "$CONTENT" in
  *"EXISTING=preserve"*"CLAUDE_SESSION_ID"*) ok "env file appended (existing content preserved)" ;;
  *) fail "env file appended" "content=$CONTENT" ;;
esac
rm -rf "$PROJ"

# Without CLAUDE_ENV_FILE, hook still works (no error, just no export).
PROJ=$(mktemp -d)
run_hook SessionStart "sid-102" "CLAUDE_PROJECT_DIR=$PROJ"
[ "$HOOK_RC" -eq 0 ] && [ -d "$PROJ/.scratch/sid-102" ] \
  && ok "SessionStart works without CLAUDE_ENV_FILE" \
  || fail "SessionStart works without CLAUDE_ENV_FILE" "rc=$HOOK_RC"
rm -rf "$PROJ"

# --- SessionStart: 7-day GC sweep -------------------------------------------
echo
echo "--- SessionStart: 7-day GC sweep ---"

PROJ=$(mktemp -d)
mkdir -p "$PROJ/.scratch"
mkdir "$PROJ/.scratch/old-dir"      && touch -d "8 days ago" "$PROJ/.scratch/old-dir"
mkdir "$PROJ/.scratch/recent-dir"   # default mtime is now
touch "$PROJ/.scratch/old-file"     && touch -d "8 days ago" "$PROJ/.scratch/old-file"
touch "$PROJ/.scratch/recent-file"

run_hook SessionStart "sid-200" "CLAUDE_PROJECT_DIR=$PROJ"

[ ! -e "$PROJ/.scratch/old-dir" ]    && ok "GC removes >7d old dir" \
  || fail "GC removes >7d old dir"
[ ! -e "$PROJ/.scratch/old-file" ]   && ok "GC removes >7d old top-level file" \
  || fail "GC removes >7d old top-level file"
[ -d "$PROJ/.scratch/recent-dir" ]   && ok "GC keeps recent dir" \
  || fail "GC keeps recent dir"
[ -e "$PROJ/.scratch/recent-file" ]  && ok "GC keeps recent file" \
  || fail "GC keeps recent file"
[ -d "$PROJ/.scratch/sid-200" ]      && ok "GC preserves the just-created session dir" \
  || fail "GC preserves the just-created session dir"

rm -rf "$PROJ"

# Edge: GC must preserve a session dir whose name matches >7d old timestamp,
# because mkdir -p on SessionStart bumps its mtime.
PROJ=$(mktemp -d)
mkdir -p "$PROJ/.scratch/sid-201"
touch -d "8 days ago" "$PROJ/.scratch/sid-201"
run_hook SessionStart "sid-201" "CLAUDE_PROJECT_DIR=$PROJ"
[ -d "$PROJ/.scratch/sid-201" ] && ok "GC preserves resumed >7d-old session via mkdir mtime bump" \
  || fail "GC preserves resumed >7d-old session via mkdir mtime bump"
rm -rf "$PROJ"

# --- SessionEnd: per-session dir removal ------------------------------------
echo
echo "--- SessionEnd: per-session dir removal ---"

PROJ=$(mktemp -d)
mkdir -p "$PROJ/.scratch/sid-300"
echo "data" > "$PROJ/.scratch/sid-300/file.txt"
run_hook SessionEnd "sid-300" "CLAUDE_PROJECT_DIR=$PROJ"
[ "$HOOK_RC" -eq 0 ] || fail "SessionEnd returns 0" "rc=$HOOK_RC"
[ ! -e "$PROJ/.scratch/sid-300" ] && ok "SessionEnd removes per-session dir" \
  || fail "SessionEnd removes per-session dir"
rm -rf "$PROJ"

# SessionEnd silent when dir doesn't exist (no error).
PROJ=$(mktemp -d)
run_hook SessionEnd "never-existed" "CLAUDE_PROJECT_DIR=$PROJ"
[ "$HOOK_RC" -eq 0 ] && ok "SessionEnd silent when dir absent" \
  || fail "SessionEnd silent when dir absent" "rc=$HOOK_RC stderr=$HOOK_STDERR"
rm -rf "$PROJ"

# SessionEnd does NOT touch sibling sessions.
PROJ=$(mktemp -d)
mkdir -p "$PROJ/.scratch/sid-301" "$PROJ/.scratch/sid-302"
run_hook SessionEnd "sid-301" "CLAUDE_PROJECT_DIR=$PROJ"
[ ! -e "$PROJ/.scratch/sid-301" ] && [ -d "$PROJ/.scratch/sid-302" ] \
  && ok "SessionEnd removes only the named session" \
  || fail "SessionEnd removes only the named session"
rm -rf "$PROJ"

# --- Missing fields: silent pass-through ------------------------------------
echo
echo "--- Missing fields: silent pass-through ---"

PROJ=$(mktemp -d)
run_hook SessionStart "" "CLAUDE_PROJECT_DIR=$PROJ"
[ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_STDERR" ] && [ ! -d "$PROJ/.scratch" ] \
  && ok "Missing session_id passes through silently" \
  || fail "Missing session_id passes through silently" "rc=$HOOK_RC stderr=$HOOK_STDERR"
rm -rf "$PROJ"

PROJ=$(mktemp -d)
run_hook "" "sid-400" "CLAUDE_PROJECT_DIR=$PROJ"
[ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_STDERR" ] && [ ! -d "$PROJ/.scratch/sid-400" ] \
  && ok "Missing hook_event_name passes through silently" \
  || fail "Missing hook_event_name passes through silently" "rc=$HOOK_RC stderr=$HOOK_STDERR"
rm -rf "$PROJ"

PROJ=$(mktemp -d)
run_hook "" "" "CLAUDE_PROJECT_DIR=$PROJ"
[ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_STDERR" ] \
  && ok "Empty input ({}) passes through silently" \
  || fail "Empty input ({}) passes through silently" "rc=$HOOK_RC stderr=$HOOK_STDERR"
rm -rf "$PROJ"

# Unknown event name: hook is a no-op (no scratch dir created).
PROJ=$(mktemp -d)
run_hook "UnknownEvent" "sid-401" "CLAUDE_PROJECT_DIR=$PROJ"
[ "$HOOK_RC" -eq 0 ] && [ ! -d "$PROJ/.scratch/sid-401" ] \
  && ok "Unknown event name is a silent no-op" \
  || fail "Unknown event name is a silent no-op"
rm -rf "$PROJ"

# --- $CLAUDE_SCRATCH_ROOT override ------------------------------------------
echo
echo "--- CLAUDE_SCRATCH_ROOT override ---"

PROJ=$(mktemp -d)
run_hook SessionStart "sid-500" \
  "CLAUDE_PROJECT_DIR=$PROJ" "CLAUDE_SCRATCH_ROOT=.custom-scratch"
[ -d "$PROJ/.custom-scratch/sid-500" ] && [ ! -d "$PROJ/.scratch" ] \
  && ok "Custom CLAUDE_SCRATCH_ROOT honoured (.custom-scratch)" \
  || fail "Custom CLAUDE_SCRATCH_ROOT honoured" "expected $PROJ/.custom-scratch/sid-500"
rm -rf "$PROJ"

# Default scratch root when env var unset → .scratch
PROJ=$(mktemp -d)
run_hook SessionStart "sid-501" "CLAUDE_PROJECT_DIR=$PROJ"
[ -d "$PROJ/.scratch/sid-501" ] && ok "Default CLAUDE_SCRATCH_ROOT is .scratch" \
  || fail "Default CLAUDE_SCRATCH_ROOT is .scratch"
rm -rf "$PROJ"

# Custom scratch root with SessionEnd: removes from the same custom root.
PROJ=$(mktemp -d)
mkdir -p "$PROJ/custom/sid-502"
run_hook SessionEnd "sid-502" \
  "CLAUDE_PROJECT_DIR=$PROJ" "CLAUDE_SCRATCH_ROOT=custom"
[ ! -e "$PROJ/custom/sid-502" ] && ok "SessionEnd uses custom CLAUDE_SCRATCH_ROOT" \
  || fail "SessionEnd uses custom CLAUDE_SCRATCH_ROOT"
rm -rf "$PROJ"

# --- $CLAUDE_PROJECT_DIR fallback to $PWD -----------------------------------
echo
echo "--- CLAUDE_PROJECT_DIR fallback to PWD ---"

PROJ=$(mktemp -d)
# env -u unsets CLAUDE_PROJECT_DIR; cd into PROJ so $PWD == $PROJ.
INPUT=$(make_input "SessionStart" "sid-600")
(
  cd "$PROJ"
  echo "$INPUT" | env -u CLAUDE_PROJECT_DIR bash "$HOOK"
)
[ -d "$PROJ/.scratch/sid-600" ] && ok "Falls back to \$PWD when CLAUDE_PROJECT_DIR unset" \
  || fail "Falls back to \$PWD when CLAUDE_PROJECT_DIR unset"
rm -rf "$PROJ"

# --- Final summary ----------------------------------------------------------
echo
echo "=================================="
echo "Results: $PASS passed, $FAIL failed"
echo "Total: $((PASS + FAIL)) tests"
echo "=================================="

[ "$FAIL" -eq 0 ] || exit 1
