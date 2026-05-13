#!/usr/bin/env bash
# Install the claude-tools git hooks for this checkout by symlinking each
# entry under scripts/git-hooks/ into <gitdir>/hooks/. Works whether
# claude-tools is checked out as a regular clone (gitdir = <repo>/.git/)
# or as a submodule (gitdir = <super>/.git/modules/<path>/).
#
# Re-runnable: existing symlinks at the destination are replaced; an
# existing real file is moved aside to <name>.backup.<timestamp> so a
# pre-existing project-local hook is never silently destroyed.
#
# Usage: scripts/install-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HOOK_SRC_DIR="$REPO_ROOT/scripts/git-hooks"

if [ ! -d "$HOOK_SRC_DIR" ]; then
  echo "error: hook source directory not found: $HOOK_SRC_DIR" >&2
  exit 1
fi

GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --git-dir)"
case "$GIT_DIR" in
  /*) ;;
  *) GIT_DIR="$REPO_ROOT/$GIT_DIR" ;;
esac
HOOK_DST_DIR="$GIT_DIR/hooks"
mkdir -p "$HOOK_DST_DIR"

shopt -s nullglob
installed=0
for src in "$HOOK_SRC_DIR"/*; do
  name="$(basename "$src")"
  # Skip dotfiles and the *.sample files git ships by default in src (none expected, but be safe).
  case "$name" in
    .*|*.sample) continue ;;
  esac

  dst="$HOOK_DST_DIR/$name"
  if [ -L "$dst" ]; then
    rm -f "$dst"
  elif [ -e "$dst" ]; then
    backup="$dst.backup.$(date +%s)"
    echo "warning: $dst exists as a regular file; backing up to $backup" >&2
    mv "$dst" "$backup"
  fi
  ln -s "$src" "$dst"
  chmod +x "$src"
  echo "installed: $dst -> $src"
  installed=$((installed + 1))
done

if [ "$installed" -eq 0 ]; then
  echo "no hooks found under $HOOK_SRC_DIR; nothing installed."
fi
