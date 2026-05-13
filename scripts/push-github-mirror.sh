#!/usr/bin/env bash
# Squash a source revision into a single root commit and force-push to
# origin/github-mirror. The github-mirror branch carries no claude-tools
# history — each run produces a fresh single-commit snapshot, so the
# public GitHub mirror exposes only the current tree.
#
# Usage:
#   scripts/push-github-mirror.sh                  # mirror main; requires local main == origin/main
#   scripts/push-github-mirror.sh <branch>         # mirror <branch>; requires local <branch> == origin/<branch>
#   scripts/push-github-mirror.sh --sha <sha>      # mirror exact <sha>, no sync check
#                                                    (intended for the pre-push hook, where the SHA
#                                                     is about to be pushed but is not yet on origin)

set -euo pipefail

# When invoked from a git hook (e.g. pre-push), the parent git process
# exports GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE pointing at the main
# repo. Subsequent git invocations inherit these and *ignore* cwd —
# meaning `git checkout --orphan` run inside a temp worktree would still
# operate on the main worktree, stranding the user on the mirror branch.
# Unset the inherited env so all git commands here resolve gitdir/worktree
# from cwd instead.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

MIRROR_BRANCH="github-mirror"
REMOTE="origin"

SOURCE_LABEL=""
SOURCE_SHA=""
SKIP_SYNC_CHECK=0

if [ "${1:-}" = "--sha" ]; then
  if [ -z "${2:-}" ]; then
    echo "error: --sha requires a value." >&2
    exit 2
  fi
  SOURCE_LABEL="$2"
  SOURCE_SHA="$2"
  SKIP_SYNC_CHECK=1
else
  SOURCE_LABEL="${1:-main}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree dirty in $REPO_ROOT; commit or stash first." >&2
  exit 1
fi

if [ "$SKIP_SYNC_CHECK" -eq 0 ]; then
  git fetch "$REMOTE" "$SOURCE_LABEL"
  SOURCE_SHA="$(git rev-parse "$SOURCE_LABEL")"
  REMOTE_SHA="$(git rev-parse "$REMOTE/$SOURCE_LABEL")"
  if [ "$SOURCE_SHA" != "$REMOTE_SHA" ]; then
    echo "error: local $SOURCE_LABEL ($SOURCE_SHA) differs from $REMOTE/$SOURCE_LABEL ($REMOTE_SHA)." >&2
    echo "       push $SOURCE_LABEL before mirroring so the mirror matches what is published." >&2
    exit 1
  fi
else
  # Validate the SHA exists locally as a commit; fail early otherwise.
  SOURCE_SHA="$(git rev-parse --verify "$SOURCE_SHA^{commit}")"
fi

# Temp worktree lives outside the gitdir. Combined with the env-var unset
# above, this gives the subshell a clean worktree context for the
# orphan-branch dance.
TMP_BASE="${TMPDIR-}"
[ -z "$TMP_BASE" ] && TMP_BASE=/tmp
WORKTREE="$(mktemp -d "$TMP_BASE/claude-tools-mirror.XXXXXX")"

cleanup() {
  if [ -d "$WORKTREE" ]; then
    git worktree remove --force "$WORKTREE" 2>/dev/null || true
    rm -rf "$WORKTREE"
  fi
  git branch -D "$MIRROR_BRANCH" 2>/dev/null || true
}
trap cleanup EXIT

# Clear any leftover local mirror branch from a previous interrupted run.
git branch -D "$MIRROR_BRANCH" 2>/dev/null || true

git worktree add --detach "$WORKTREE" "$SOURCE_SHA"
(
  cd "$WORKTREE"
  git checkout --orphan "$MIRROR_BRANCH"
  git add -A
  git commit -m "Snapshot of $SOURCE_LABEL @ $SOURCE_SHA"
  git push --force "$REMOTE" "$MIRROR_BRANCH"
)

echo "Pushed $REMOTE/$MIRROR_BRANCH @ snapshot of $SOURCE_LABEL ($SOURCE_SHA)."
