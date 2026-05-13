#!/usr/bin/env bash
# Squash $SOURCE_BRANCH (default: main) into a single root commit and
# force-push to origin/github-mirror. The github-mirror branch carries no
# claude-tools history — each run produces a fresh single-commit snapshot,
# so the public GitHub mirror exposes only the current tree.
#
# Usage: scripts/push-github-mirror.sh [source-branch]

set -euo pipefail

SOURCE_BRANCH="${1:-main}"
MIRROR_BRANCH="github-mirror"
REMOTE="origin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree dirty in $REPO_ROOT; commit or stash first." >&2
  exit 1
fi

git fetch "$REMOTE" "$SOURCE_BRANCH"

SOURCE_SHA="$(git rev-parse "$SOURCE_BRANCH")"
REMOTE_SHA="$(git rev-parse "$REMOTE/$SOURCE_BRANCH")"
if [ "$SOURCE_SHA" != "$REMOTE_SHA" ]; then
  echo "error: local $SOURCE_BRANCH ($SOURCE_SHA) differs from $REMOTE/$SOURCE_BRANCH ($REMOTE_SHA)." >&2
  echo "       push $SOURCE_BRANCH before mirroring so the mirror matches what is published." >&2
  exit 1
fi

GIT_DIR="$(git rev-parse --git-dir)"
WORKTREE="$GIT_DIR/mirror-worktree"

cleanup() {
  git worktree remove --force "$WORKTREE" 2>/dev/null || true
  rm -rf "$WORKTREE"
  git branch -D "$MIRROR_BRANCH" 2>/dev/null || true
}
trap cleanup EXIT

cleanup

git worktree add --detach "$WORKTREE" "$SOURCE_SHA"
(
  cd "$WORKTREE"
  git checkout --orphan "$MIRROR_BRANCH"
  git add -A
  git commit -m "Snapshot of $SOURCE_BRANCH @ $SOURCE_SHA"
  git push --force "$REMOTE" "$MIRROR_BRANCH"
)

echo "Pushed $REMOTE/$MIRROR_BRANCH @ snapshot of $SOURCE_BRANCH ($SOURCE_SHA)."
