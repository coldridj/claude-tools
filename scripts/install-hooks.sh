#!/usr/bin/env bash
# install-hooks.sh — wire claude-tools hooks into the consumer project.
#
# Installs two kinds of hook in one pass:
#
#   1. Claude Code hooks (PreToolUse / SessionStart / SessionEnd / etc.).
#      Each hook subdir under hooks/ is symlinked at
#      <consumer-project>/.claude/hooks/<name>. Activate by registering
#      the hook script in <consumer-project>/.claude/settings.json with
#      the appropriate matcher — installing the symlink is a prerequisite
#      but not sufficient on its own. Relative symlinks (computed from
#      the link's parent dir) so .claude/hooks/ is committable.
#
#   2. Git hooks (pre-commit / post-merge / pre-push / etc.). Each entry
#      under scripts/git-hooks/ is symlinked into <gitdir>/hooks/. Git
#      invokes them automatically — no registration step needed.
#
# Consumer project resolution (where Claude hooks land):
#
#   - When claude-tools is checked out as a submodule of a larger repo:
#     install into the SUPERPROJECT's .claude/hooks/, not the submodule's
#     own. Detected via `git rev-parse --show-superproject-working-tree`.
#   - When claude-tools is a regular clone (no superproject): install
#     into its own .claude/hooks/.
#
# Git hooks always land in the script-dir's clone (so submodule git hooks
# like pre-push fire on the submodule's own commits, not the
# superproject's).
#
# Re-runnable: existing symlinks at each destination are replaced; an
# existing real file is moved aside to <name>.backup.<timestamp> so a
# pre-existing project-local hook is never silently destroyed.
#
# Usage: scripts/install-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_TOOLS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Resolve the Claude-hooks consumer root: the superproject if claude-tools
# is a submodule, otherwise this clone's own top-level. The git hooks
# destination always anchors on this clone's gitdir.
SUPER_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
CLONE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CLAUDE_CONSUMER_ROOT="${SUPER_ROOT:-$CLONE_ROOT}"

# Replace a destination symlink/file with a new symlink at $dst pointing
# at $target. Backs up pre-existing real files; replaces existing symlinks
# in place.
install_link() {
  local target="$1" dst="$2"
  if [ -L "$dst" ]; then
    rm -f "$dst"
  elif [ -e "$dst" ]; then
    local backup="$dst.backup.$(date +%s)"
    echo "warning: $dst exists as a regular file; backing up to $backup" >&2
    mv "$dst" "$backup"
  fi
  ln -s "$target" "$dst"
}

shopt -s nullglob

# ----- Claude Code hooks -----

CLAUDE_HOOKS_SRC="$CLAUDE_TOOLS_ROOT/hooks"
CLAUDE_HOOKS_DST="$CLAUDE_CONSUMER_ROOT/.claude/hooks"
mkdir -p "$CLAUDE_HOOKS_DST"

claude_installed=0
for src in "$CLAUDE_HOOKS_SRC"/*; do
  name="$(basename "$src")"
  # Skip non-hook entries: shared helpers (lib/), the cross-hook runner
  # (test-all.sh), the cross-hook hardening guide (HARDENING.md), and any
  # other tooling-internal file. Each hook lives in its own subdir; only
  # those + a top-level README get linked.
  case "$name" in
    .*|lib|test-all.sh|HARDENING.md) continue ;;
  esac
  if [ ! -d "$src" ] && [ "$name" != "README.md" ]; then
    continue
  fi

  rel="$(realpath --relative-to="$CLAUDE_HOOKS_DST" "$src")"
  install_link "$rel" "$CLAUDE_HOOKS_DST/$name"
  echo "installed: $CLAUDE_HOOKS_DST/$name -> $rel"
  claude_installed=$((claude_installed + 1))
done

if [ "$claude_installed" -eq 0 ]; then
  echo "no Claude Code hooks found under $CLAUDE_HOOKS_SRC; nothing installed."
fi

# ----- Git hooks -----

GIT_HOOK_SRC_DIR="$CLAUDE_TOOLS_ROOT/scripts/git-hooks"
if [ -d "$GIT_HOOK_SRC_DIR" ]; then
  GIT_DIR="$(git -C "$CLONE_ROOT" rev-parse --git-dir)"
  case "$GIT_DIR" in
    /*) ;;
    *)  GIT_DIR="$CLONE_ROOT/$GIT_DIR" ;;
  esac
  GIT_HOOK_DST_DIR="$GIT_DIR/hooks"
  mkdir -p "$GIT_HOOK_DST_DIR"

  git_installed=0
  for src in "$GIT_HOOK_SRC_DIR"/*; do
    name="$(basename "$src")"
    case "$name" in
      .*|*.sample) continue ;;
    esac
    install_link "$src" "$GIT_HOOK_DST_DIR/$name"
    chmod +x "$src"
    echo "installed: $GIT_HOOK_DST_DIR/$name -> $src"
    git_installed=$((git_installed + 1))
  done

  if [ "$git_installed" -eq 0 ]; then
    echo "no git hooks found under $GIT_HOOK_SRC_DIR; nothing installed."
  fi
fi
