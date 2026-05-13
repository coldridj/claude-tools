#!/usr/bin/env bash
# Tests for scripts/push-github-mirror.sh.
#
# Each test builds a self-contained sandbox with:
#   <tmp>/src         working repo (the "superproject" being mirrored)
#   <tmp>/origin.git  bare repo acting as origin remote
#
# The script under test is copied into <tmp>/src/scripts/ so its REPO_ROOT
# probe (`git -C "$SCRIPT_DIR" rev-parse --show-toplevel`) resolves to the
# sandbox, never the real claude-tools repo. A regression that tried to
# push to its own origin therefore cannot hit a real remote.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/push-github-mirror.sh"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ — $2}"; }

# Build a fresh sandbox; echo its path.
make_sandbox() {
  local tmp src origin
  tmp="$(mktemp -d)"
  src="$tmp/src"
  origin="$tmp/origin.git"

  git init -q -b main "$src"
  git -C "$src" config user.email "test@example.com"
  git -C "$src" config user.name  "Test"
  git -C "$src" config commit.gpgsign false

  mkdir -p "$src/scripts"

  echo "root" > "$src/README"
  git -C "$src" add README
  git -C "$src" commit -q -m "root"

  echo "v2" > "$src/file.txt"
  git -C "$src" add file.txt
  git -C "$src" commit -q -m "second"

  git init -q --bare "$origin"
  git -C "$src" remote add origin "$origin"
  git -C "$src" push -q origin main

  cp "$SCRIPT_UNDER_TEST" "$src/scripts/push-github-mirror.sh"
  chmod +x "$src/scripts/push-github-mirror.sh"

  echo "$tmp"
}

mirror_msg() { git --git-dir="$1" log -1 --pretty=%s github-mirror; }
mirror_tip() { git --git-dir="$1" rev-parse github-mirror; }
tag_sha()    { git --git-dir="$1" rev-list -n1 "refs/tags/$2"; }

echo "=== push-github-mirror tests ==="

# --- Manual: mirror by branch label ----------------------------------------
echo
echo "--- Manual: mirror by branch label ---"

TMP="$(make_sandbox)"
SRC="$TMP/src"
ORIGIN="$TMP/origin.git"
SHORT="$(git -C "$SRC" rev-parse --short main)"

if (cd "$SRC" && bash scripts/push-github-mirror.sh main) >/dev/null 2>&1; then
  ok "manual run exits 0"
else
  fail "manual run exits 0"
fi

MSG="$(mirror_msg "$ORIGIN")"
EXPECT="Snapshot of main @ $SHORT"
[ "$MSG" = "$EXPECT" ] \
  && ok "manual: commit message 'Snapshot of <label> @ <short>'" \
  || fail "manual: commit message" "got='$MSG' want='$EXPECT'"

[ "$(tag_sha "$ORIGIN" latest)" = "$(mirror_tip "$ORIGIN")" ] \
  && ok "manual: 'latest' tag points at mirror tip" \
  || fail "manual: 'latest' tag points at mirror tip"

rm -rf "$TMP"

# --- --sha: mirror by exact SHA (pre-push hook path) -----------------------
echo
echo "--- --sha: mirror by exact SHA ---"

TMP="$(make_sandbox)"
SRC="$TMP/src"
ORIGIN="$TMP/origin.git"
FULL="$(git -C "$SRC" rev-parse main)"
SHORT="$(git -C "$SRC" rev-parse --short main)"

if (cd "$SRC" && bash scripts/push-github-mirror.sh --sha "$FULL") >/dev/null 2>&1; then
  ok "--sha run exits 0"
else
  fail "--sha run exits 0"
fi

MSG="$(mirror_msg "$ORIGIN")"
EXPECT="Snapshot @ $SHORT"
[ "$MSG" = "$EXPECT" ] \
  && ok "--sha: commit message 'Snapshot @ <short>'  (no redundant <sha> @ <sha>)" \
  || fail "--sha: commit message" "got='$MSG' want='$EXPECT'"

[ "$(tag_sha "$ORIGIN" latest)" = "$(mirror_tip "$ORIGIN")" ] \
  && ok "--sha: 'latest' tag points at mirror tip" \
  || fail "--sha: 'latest' tag points at mirror tip"

rm -rf "$TMP"

# --- Manual: mirror a non-main branch --------------------------------------
echo
echo "--- Manual: mirror non-main branch ---"

TMP="$(make_sandbox)"
SRC="$TMP/src"
ORIGIN="$TMP/origin.git"

git -C "$SRC" checkout -q -b feature
echo "feat" > "$SRC/feat.txt"
git -C "$SRC" add feat.txt
git -C "$SRC" commit -q -m "feature"
git -C "$SRC" push -q origin feature
SHORT="$(git -C "$SRC" rev-parse --short feature)"

if (cd "$SRC" && bash scripts/push-github-mirror.sh feature) >/dev/null 2>&1; then
  ok "feature-branch run exits 0"
else
  fail "feature-branch run exits 0"
fi

MSG="$(mirror_msg "$ORIGIN")"
EXPECT="Snapshot of feature @ $SHORT"
[ "$MSG" = "$EXPECT" ] \
  && ok "feature: commit message 'Snapshot of feature @ <short>'" \
  || fail "feature: commit message" "got='$MSG' want='$EXPECT'"

rm -rf "$TMP"

# --- Final summary ---------------------------------------------------------
echo
echo "=================================="
echo "Results: $PASS passed, $FAIL failed"
echo "Total: $((PASS + FAIL)) tests"
echo "=================================="

[ "$FAIL" -eq 0 ] || exit 1
