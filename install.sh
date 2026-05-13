#!/usr/bin/env bash
# install.sh — symlink each item under hooks/ into the parent project's
# .claude/hooks/ directory.
#
# Run from a project that has claude-tools added as a submodule:
#
#     bash git_modules/claude-tools/install.sh           # prompt per item
#     bash git_modules/claude-tools/install.sh --all     # install every item, no prompts
#     bash git_modules/claude-tools/install.sh --dry-run # report only, no changes
#     bash git_modules/claude-tools/install.sh --force   # overwrite regular files at target
#     bash git_modules/claude-tools/install.sh --help
#
# The script auto-detects the superproject via `git rev-parse
# --show-superproject-working-tree`. It will refuse to run if claude-tools is
# not a submodule (no superproject) so it cannot accidentally symlink into
# whatever directory you happen to be in.
#
# Each hook lives in its own subdirectory under hooks/. The install script
# also picks up top-level files (e.g. README.md). The resulting symlinks use
# repo-relative targets so they survive moves of the whole project tree.
#
# Side-effect for path-guard:
#   When path-guard is installed (or already correctly symlinked), this
#   script also ensures the superproject has a project-local .path-guard
#   file with [protected] patterns covering the submodule's real hook
#   paths. path-guard normalises through symlinks, so without that file the
#   shipped pattern `.claude/hooks/**/hook.sh` would not match writes whose
#   realpath resolves into the submodule. The submodule path is detected
#   from this script's location (relative to the superproject), so it works
#   whether claude-tools lives at git_modules/claude-tools, vendor/claude-tools,
#   or anywhere else.
#
# Existing symlinks at the target are silently updated when they point at the
# wrong place. Real files/directories at the target require --force to be
# replaced — this avoids destroying project-local hooks that happen to share
# a name with one in claude-tools.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC_DIR="$SCRIPT_DIR/hooks"

ALL=0
DRY=0
FORCE=0

usage() {
  cat <<'EOF'
install.sh — symlink each item under hooks/ into the parent project's
.claude/hooks/ directory.

Run from a project that has claude-tools added as a submodule:

    bash git_modules/claude-tools/install.sh           # prompt per item
    bash git_modules/claude-tools/install.sh --all     # install everything
    bash git_modules/claude-tools/install.sh --dry-run # show what would change
    bash git_modules/claude-tools/install.sh --force   # overwrite regular files
    bash git_modules/claude-tools/install.sh --help

Options:
  --all, -a       Install every item without prompting.
  --dry-run, -n   Print what would change; touch nothing.
  --force, -f     Replace existing regular files. (Symlinks always update.)
  --help, -h      Show this help.

Prompt answers: Y install / n skip / a install all remaining / q quit.

When path-guard is installed, the script also writes (or extends) a project-
local .path-guard at the superproject root with [protected] patterns
covering the submodule's real hook paths. path-guard's symlink-resolving
normaliser would otherwise miss writes whose realpath resolves into the
submodule. The submodule's path is detected from this script's location, so
the rule works whether claude-tools lives at git_modules/claude-tools,
vendor/claude-tools, or anywhere else.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --all|-a)     ALL=1 ;;
    --dry-run|-n) DRY=1 ;;
    --force|-f)   FORCE=1 ;;
    --help|-h)    usage; exit 0 ;;
    *)            printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ ! -d "$SRC_DIR" ]; then
  printf 'install.sh: expected a hooks/ directory at %s\n' "$SRC_DIR" >&2
  exit 1
fi

SUPER=$(git -C "$SCRIPT_DIR" rev-parse --show-superproject-working-tree 2>/dev/null || true)
if [ -z "$SUPER" ]; then
  printf 'install.sh: claude-tools must be added as a submodule of a parent project.\n' >&2
  printf '  From the parent project root, run:\n' >&2
  printf '    git submodule add <url> git_modules/claude-tools\n' >&2
  exit 1
fi

DEST="$SUPER/.claude/hooks"
SUBMODULE_REL=$(realpath --relative-to="$SUPER" "$SCRIPT_DIR")

mapfile -t ITEMS < <(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
if [ "${#ITEMS[@]}" -eq 0 ]; then
  printf 'install.sh: %s is empty — nothing to install.\n' "$SRC_DIR" >&2
  exit 1
fi

printf 'Superproject: %s\n' "$SUPER"
printf 'Submodule:    %s  (repo-relative: %s)\n' "$SCRIPT_DIR" "$SUBMODULE_REL"
printf 'Destination:  %s\n' "$DEST"
if [ "$DRY" -eq 1 ]; then
  printf '(dry-run: no filesystem changes will be made)\n'
fi
printf '\n'

if [ "$DRY" -eq 0 ]; then
  mkdir -p "$DEST"
fi

installed=0; replaced=0; skipped=0; conflicted=0; unchanged=0

prompt() {
  # Read from /dev/tty so prompts work even when stdin is piped.
  local name="$1" answer
  while true; do
    printf 'Install symlink for %s? [Y/n/a/q] ' "$name" > /dev/tty
    if ! read -r answer < /dev/tty; then
      printf '\nAborted.\n'
      exit 0
    fi
    case "${answer:-Y}" in
      Y|y)   return 0 ;;
      N|n)   return 1 ;;
      A|a)   ALL=1; return 0 ;;
      Q|q)   printf 'Aborted.\n'; exit 0 ;;
      *)     printf '  (Y = install, n = skip, a = install all remaining, q = quit)\n' > /dev/tty ;;
    esac
  done
}

# ensure_path_guard_config: write or extend $SUPER/.path-guard so it covers
# the submodule's realpath-resolved hook directories. Idempotent — if the
# patterns are already present (anywhere in the file), do nothing.
ensure_path_guard_config() {
  local cfg="$SUPER/.path-guard"
  local hook_pat="${SUBMODULE_REL}/hooks/**/hook.sh"
  local compact_pat="${SUBMODULE_REL}/hooks/**/compact.sh"

  local need_hook=1 need_compact=1
  if [ -f "$cfg" ]; then
    grep -qFx -- "$hook_pat"    "$cfg" 2>/dev/null && need_hook=0
    grep -qFx -- "$compact_pat" "$cfg" 2>/dev/null && need_compact=0
  fi
  if [ "$need_hook" -eq 0 ] && [ "$need_compact" -eq 0 ]; then
    printf '    .path-guard already protects %s/hooks (no change)\n' "$SUBMODULE_REL"
    return 0
  fi

  if [ "$DRY" -eq 1 ]; then
    if [ -f "$cfg" ]; then
      printf '    would append submodule protection patterns to %s\n' "$cfg"
    else
      printf '    would create %s with submodule protection patterns\n' "$cfg"
    fi
    return 0
  fi

  if [ ! -f "$cfg" ]; then
    cat > "$cfg" <<EOF
# .path-guard — project-specific path-guard rules.
#
# Loaded by the path-guard hook after default.path-guard (shipped) and
# \$HOME/.claude/.path-guard (user defaults).
#
# Sections:
#   [secret]    — block Read AND Write
#   [protected] — block Write only

[protected]

# Managed by claude-tools install.sh: protect the realpath-resolved hook
# scripts so a symlinked .claude/hooks/<name>/hook.sh stays write-blocked.
$hook_pat
$compact_pat
EOF
    printf '    wrote %s\n' "$cfg"
    return 0
  fi

  # Append to existing file. Ensure trailing newline first.
  if [ -s "$cfg" ] && [ "$(tail -c 1 "$cfg")" != $'\n' ]; then
    printf '\n' >> "$cfg"
  fi
  {
    printf '\n[protected]\n'
    printf '# Added by claude-tools install.sh: protect the realpath-resolved hook\n'
    printf '# scripts so a symlinked .claude/hooks/<name>/hook.sh stays write-blocked.\n'
    [ "$need_hook"    -eq 1 ] && printf '%s\n' "$hook_pat"
    [ "$need_compact" -eq 1 ] && printf '%s\n' "$compact_pat"
  } >> "$cfg"
  printf '    appended submodule protection patterns to %s\n' "$cfg"
}

install_one() {
  local name="$1"
  local src="$SRC_DIR/$name"
  local dest="$DEST/$name"
  local rel
  rel=$(realpath -m --relative-to="$DEST" "$src")
  local action=""   # one of: install, update, unchanged, overwrite, conflict

  if [ -L "$dest" ]; then
    local current
    current=$(readlink "$dest")
    if [ "$current" = "$rel" ]; then
      printf '  = %s (already correct)\n' "$name"
      unchanged=$((unchanged + 1))
      action="unchanged"
    else
      if [ "$DRY" -eq 1 ]; then
        printf '  ~ would update %s (was: %s -> now: %s)\n' "$name" "$current" "$rel"
      else
        ln -sfn "$rel" "$dest"
        printf '  ~ updated %s (was: %s)\n' "$name" "$current"
      fi
      replaced=$((replaced + 1))
      action="update"
    fi
  elif [ -e "$dest" ]; then
    if [ "$FORCE" -ne 1 ]; then
      printf '  ! %s exists and is not a symlink — pass --force to replace it\n' "$name"
      conflicted=$((conflicted + 1))
      action="conflict"
    else
      if [ "$DRY" -eq 1 ]; then
        printf '  ~ would overwrite %s (existing file/dir)\n' "$name"
      else
        rm -rf "$dest"
        ln -s "$rel" "$dest"
        printf '  ~ overwrote %s (regular file/dir -> symlink)\n' "$name"
      fi
      replaced=$((replaced + 1))
      action="overwrite"
    fi
  else
    if [ "$DRY" -eq 1 ]; then
      printf '  + would install %s -> %s\n' "$name" "$rel"
    else
      ln -s "$rel" "$dest"
      printf '  + installed %s -> %s\n' "$name" "$rel"
    fi
    installed=$((installed + 1))
    action="install"
  fi

  # Per-hook follow-up actions. Path-guard needs a project-local .path-guard
  # to keep protection in place once its hook script lives behind a symlink.
  case "$name" in
    path-guard)
      if [ "$action" != "conflict" ]; then
        ensure_path_guard_config
      fi
      ;;
  esac
}

for name in "${ITEMS[@]}"; do
  if [ "$ALL" -eq 1 ]; then
    install_one "$name"
  elif prompt "$name"; then
    install_one "$name"
  else
    printf '  - skipped %s\n' "$name"
    skipped=$((skipped + 1))
  fi
done

printf '\nDone: %d installed, %d updated, %d unchanged, %d skipped, %d conflicts.\n' \
  "$installed" "$replaced" "$unchanged" "$skipped" "$conflicted"

if [ "$conflicted" -gt 0 ]; then
  exit 1
fi
exit 0
