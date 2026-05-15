#!/usr/bin/env bash
# path-guard: PreToolUse hook — blocks file operations outside allowed directories
# and writes/reads to files matching configured rules.
#
# Allowed roots (writes outside these are always blocked):
#   $CLAUDE_PROJECT_DIR     — the current project tree
#   $HOME/.claude           — Claude Code user configuration
#
# Rule files (concatenated, in load order):
#   1. .claude/hooks/path-guard/default.path-guard  (shipped with the hook)
#   2. $HOME/.claude/.path-guard                    (user defaults)
#   3. $CLAUDE_PROJECT_DIR/.path-guard              (project rules)
#
# Each file has up to two sections:
#   [secret]     — block Read AND Write (file is sensitive)
#   [protected]  — block Write only (file is readable for inspection)
#
# Pattern syntax (gitignore-flavoured glob):
#   *             matches any chars within a segment (no /)
#   **            matches any number of path segments
#   ?             one char (no /)
#   [abc]         char class
#   ~             leading tilde expands to $HOME
#   leading /     anchors to filesystem root
#   no leading /  matches as basename or path-suffix
#   trailing /**  also matches the directory itself
#
# Tools handled:
#   Read                                — blocks if path matches [secret]
#   Edit, Write, MultiEdit, NotebookEdit — zone check, then [secret]/[protected]
#   Bash                                — zone check on redirect/tee targets;
#                                         backstop blocks any write operator on
#                                         the same line as a [secret]/[protected]
#                                         path mention.
#
# Bash backstop hardening passes:
#   - Newlines (incl. line-continuation \-NL) are normalised to spaces before
#     regex matching, so write-op and path on different physical lines still
#     trigger the backstop.
#   - Per-char pattern regex also accepts `?` and `[x]` glob substitutions in
#     command text (bash expands them at exec time).
#   - Brace-expansion `{a,b}` in a path token combined with a write op is
#     blocked (cannot be statically verified).
#   - Tree-walking commands (find -delete/-exec, tar -x, unzip, rsync, rm -r)
#     are additionally matched against the directory-prefix of any protected
#     or secret pattern.
#   - Each pattern's command-text regex is word-bounded on both sides so
#     basename patterns like `.git` don't match inside `origin.git`,
#     `.claude` doesn't match inside `myclaude/...`, etc.
#   - Command-name patterns (`\bcp\b`, `\binstall\b`, etc.) are statement-
#     anchored: the command must be the first token of a statement (start
#     of line, or after `;`/`&`/`|`/`(`/`{`/backtick) — otherwise filename
#     substrings like `install-hooks.sh` produce false positives. The `>` /
#     `>>` redirect operators remain unanchored. Closes task #19 and the
#     related BUGS.md entry.
#
# Repeat-suppression: after the first write-block per session, subsequent
# blocks emit a short one-liner instead of the full scratch+mv workflow,
# saving tokens. Implemented via a `$CLAUDE_SESSION_SCRATCH/.path-guard-seen`
# marker file. Only active when CLAUDE_SESSION_SCRATCH is set — unit tests
# don't export it, so the full message is always tested.
#
# Known limitations (covered by bash-guard or out-of-scope):
#   - $VAR / $(cmd) redirect targets cannot be analysed statically.
#   - Relative redirect/tee targets above the project root (../../etc/x) are not
#     captured for zone enforcement; only absolute, ~, and quoted forms are.
#   - Indirect execution (base64 | sh, bash -c '<destructive>') is bash-guard's
#     domain. Statement-start anchoring deliberately does NOT detect commands
#     hidden inside a quoted bash -c argument; bash-guard's exec-string parser
#     handles those.
#   - `cp src dst` / `install src dst` / `ln src dst` cannot distinguish read
#     source from write destination; a protected source still triggers the
#     backstop. See BUGS.md (path-guard, cp/install/ln direction-blindness).

set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROJECT_DIR=$(realpath -m "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")
CLAUDE_DIR=$(realpath -m "$HOME/.claude" 2>/dev/null || echo "$HOME/.claude")
HOOK_DIR="${PATH_GUARD_HOOK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ============================================================================
# Config loader
# ============================================================================

SECRET_PATTERNS=()
PROTECTED_PATTERNS=()

load_config() {
  local file="$1" line section=""
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    if [[ "$line" =~ ^\[([a-z]+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    case "$section" in
      secret)    SECRET_PATTERNS+=("$line") ;;
      protected) PROTECTED_PATTERNS+=("$line") ;;
      *)         continue ;;
    esac
  done < "$file"
}

load_config "$HOOK_DIR/default.path-guard"
load_config "$HOME/.claude/.path-guard"
load_config "$PROJECT_DIR/.path-guard"

# ============================================================================
# Path normalisation
# ============================================================================

normalize_path() {
  local p="$1"
  case "$p" in
    \"*\") p="${p#\"}"; p="${p%\"}" ;;
    \'*\') p="${p#\'}"; p="${p%\'}" ;;
  esac
  case "$p" in
    "~")    p="$HOME" ;;
    "~/"*)  p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in
    /*) ;;
    *)  p="$PROJECT_DIR/$p" ;;
  esac
  realpath -m "$p" 2>/dev/null || printf '%s' "$p"
}

# ============================================================================
# Pattern matching: gitignore-flavoured glob → bash case match
# ============================================================================

# Test whether $1 (an absolute path) matches glob $2.
path_matches_pattern() {
  local path="$1" pat="$2"
  case "$pat" in
    "~")    pat="$HOME" ;;
    "~/"*)  pat="$HOME/${pat#\~/}" ;;
  esac
  local also_dir=""
  case "$pat" in
    */\*\*) also_dir="${pat%/\*\*}" ;;
  esac
  local clean="${pat//\*\*/*}"
  case "$pat" in
    /*)
      # shellcheck disable=SC2254
      case "$path" in $clean) return 0 ;; esac
      ;;
    *)
      # shellcheck disable=SC2254
      case "$path" in $clean) return 0 ;; esac
      # shellcheck disable=SC2254
      case "$path" in */$clean) return 0 ;; esac
      ;;
  esac
  if [ -n "$also_dir" ]; then
    case "$also_dir" in
      /*)
        # shellcheck disable=SC2254
        case "$path" in $also_dir) return 0 ;; esac
        ;;
      *)
        # shellcheck disable=SC2254
        case "$path" in $also_dir) return 0 ;; esac
        # shellcheck disable=SC2254
        case "$path" in */$also_dir) return 0 ;; esac
        ;;
    esac
  fi
  return 1
}

path_matches_any() {
  local path="$1"; shift
  local pat
  for pat in "$@"; do
    if path_matches_pattern "$path" "$pat"; then
      return 0
    fi
  done
  return 1
}

is_secret() {
  local abs
  abs=$(normalize_path "$1")
  [ "${#SECRET_PATTERNS[@]}" -eq 0 ] && return 1
  path_matches_any "$abs" "${SECRET_PATTERNS[@]}"
}

# Returns true if path is in EITHER section — either is write-blocked.
is_write_blocked() {
  local abs
  abs=$(normalize_path "$1")
  if [ "${#PROTECTED_PATTERNS[@]}" -gt 0 ] && path_matches_any "$abs" "${PROTECTED_PATTERNS[@]}"; then
    return 0
  fi
  if [ "${#SECRET_PATTERNS[@]}" -gt 0 ] && path_matches_any "$abs" "${SECRET_PATTERNS[@]}"; then
    return 0
  fi
  return 1
}

# ============================================================================
# Zone check (writes outside allowed roots are always blocked)
# ============================================================================

is_in_allowed_zone() {
  local path="$1"
  case "$path" in
    /dev/null|/dev/stdout|/dev/stderr|/dev/stdin|/dev/fd/*) return 0 ;;
  esac
  local abs
  abs=$(normalize_path "$path")
  case "$abs" in
    "$PROJECT_DIR"|"$PROJECT_DIR"/*) return 0 ;;
    "$CLAUDE_DIR"|"$CLAUDE_DIR"/*)   return 0 ;;
    *) return 1 ;;
  esac
}

# ============================================================================
# Bash command backstop: convert each rule's glob into a regex fragment that
# matches the path's appearance in command text. Pre-build one ERE per side.
# ============================================================================

# Convert a glob pattern to a regex fragment matching its appearance in a
# command line. Tilde patterns produce both ~/... and $HOME/... variants.
# Every literal character in the pattern is wrapped so it also accepts a
# `?` or `[x]` glob substitution at the same position in the command text —
# bash glob-expands those at exec time, but the literal text would otherwise
# evade the substring regex.
glob_to_command_regex() {
  local pat="$1"
  pat="${pat%/\*\*}"
  pat="${pat%\*\*}"
  local home_variant=""
  case "$pat" in
    "~")    home_variant="$HOME" ;;
    "~/"*)  home_variant="$HOME/${pat#\~/}" ;;
  esac
  # Glob-meta alternative for one literal position: a `?` glob or a `[…]` class.
  local GLOB_META='\?|\[[^]]*\]'
  local v
  local out=""
  for v in "$pat" "$home_variant"; do
    [ -z "$v" ] && continue
    [ "$v" = "$pat" ] && [ -n "$home_variant" ] && [ "$pat" = "$home_variant" ] && continue
    local re="" i ch nch
    for (( i=0; i<${#v}; i++ )); do
      ch="${v:i:1}"
      nch="${v:i+1:1}"
      case "$ch" in
        '*')
          if [ "$nch" = '*' ]; then
            re+='.*'
            i=$((i+1))
          else
            re+='[^/[:space:]"'"'"'\\|&;<>]*'
          fi
          ;;
        '?')          re+='[^/[:space:]"'"'"'\\|&;<>]'  ;;
        '/')          re+='/+' ;;
        '.'|'+'|'('|')'|'{'|'}'|'$'|'^'|'|')
          re+="(\\$ch|${GLOB_META})"
          ;;
        '['|']')      re+="$ch" ;;
        '~')          re+='~' ;;
        *)            re+="(${ch}|${GLOB_META})" ;;
      esac
    done
    if [ -n "$out" ]; then out+="|"; fi
    out+="$re"
  done
  printf '%s' "$out"
}

# Word-boundary chars that bookend a path mention in command text. Excludes
# alnum, dot, underscore, hyphen — so `.git` won't match inside `origin.git`,
# `.claude` won't match `myclaude` or `.claude-backup`, etc. Allowed: `/`,
# whitespace, quotes, redirect/shell operators.
BOUNDARY_CHAR='[^A-Za-z0-9._-]'

build_path_regex() {
  local joined="" pat re wrapped
  for pat in "$@"; do
    re=$(glob_to_command_regex "$pat")
    [ -z "$re" ] && continue
    wrapped="(^|${BOUNDARY_CHAR})(${re})(${BOUNDARY_CHAR}|\$)"
    if [ -z "$joined" ]; then joined="$wrapped"; else joined="${joined}|${wrapped}"; fi
  done
  [ -z "$joined" ] && return 0
  printf '(%s)' "$joined"
}

# Produce the directory prefix of a pattern (the protected directory tree).
# Used for tree-walking commands where the destructive op operates on a
# search root rather than the full file path.
#
#   .claude/settings.json     → .claude
#   .claude/hooks/**/hook.sh  → .claude/hooks
#   ~/.aws/**                 → ~/.aws
#   /etc/sudoers.d/**         → /etc/sudoers.d
#   /etc/shadow               → /etc
#   CLAUDE.md (no slash)      → ""  (no useful directory anchor)
pattern_dir_prefix() {
  local pat="$1"
  case "$pat" in
    */*) ;;
    *)   return 0 ;;
  esac
  case "$pat" in
    */\*\*) pat="${pat%/\*\*}" ;;
    */\*)   pat="${pat%/\*}" ;;
    *)      pat="${pat%/*}" ;;
  esac
  case "$pat" in
    */\*\*) pat="${pat%/\*\*}" ;;
    */\*)   pat="${pat%/\*}" ;;
  esac
  [ -z "$pat" ] && return 0
  printf '%s' "$pat"
}

build_dir_prefix_regex() {
  local joined="" pat prefix re seen=" " wrapped
  for pat in "$@"; do
    prefix=$(pattern_dir_prefix "$pat")
    [ -z "$prefix" ] && continue
    case "$seen" in *" $prefix "*) continue ;; esac
    seen+="$prefix "
    re=$(glob_to_command_regex "$prefix")
    [ -z "$re" ] && continue
    wrapped="(^|${BOUNDARY_CHAR})(${re})(${BOUNDARY_CHAR}|\$)"
    if [ -z "$joined" ]; then joined="$wrapped"; else joined="${joined}|${wrapped}"; fi
  done
  [ -z "$joined" ] && return 0
  printf '(%s)' "$joined"
}

PROTECTED_RE=""
[ "${#PROTECTED_PATTERNS[@]}" -gt 0 ] && PROTECTED_RE=$(build_path_regex "${PROTECTED_PATTERNS[@]}")
SECRET_RE=""
[ "${#SECRET_PATTERNS[@]}" -gt 0 ] && SECRET_RE=$(build_path_regex "${SECRET_PATTERNS[@]}")
PROTECTED_DIRS_RE=""
[ "${#PROTECTED_PATTERNS[@]}" -gt 0 ] && PROTECTED_DIRS_RE=$(build_dir_prefix_regex "${PROTECTED_PATTERNS[@]}")
SECRET_DIRS_RE=""
[ "${#SECRET_PATTERNS[@]}" -gt 0 ] && SECRET_DIRS_RE=$(build_dir_prefix_regex "${SECRET_PATTERNS[@]}")

# Statement-start anchor: a command name must appear as the first token of a
# logical statement — start-of-line, or after one of `;`/`&`/`|`/`(`/`{`/backtick
# followed by optional whitespace. Without this, `\binstall\b` matched `install`
# *inside* filenames (e.g. `bash scripts/install-hooks.sh`), producing false
# positives — task #19 and the BUGS.md "WRITE_CMDS_RE substring" entry.
#
# Why these separators specifically:
#   ;      sequential statement separator
#   |      pipe (single, also part of ||)
#   &      background, also part of &&
#   (      subshell (rm /foo)
#   {      brace group { rm /foo; }
#   `      backtick command substitution
# `$(...)` is covered by `(` since COMMAND_FLAT strips no parentheses.
# Quoted forms (`'rm /foo'`, `"rm /foo"`) lose their quotes in COMMAND_FLAT
# and become un-anchored mid-string — those are bash-guard's domain
# (indirect execution via `bash -c`).
STMT_START='(^|[;&|({`][[:space:]]*)'

# Programs/operators that write to a file. cat/head/grep/less are excluded —
# those are read-guard's domain. Some entries require a destructive flag
# (e.g. tar -x, gawk -i inplace, curl -o) so a read-only invocation of the
# same binary does not get falsely flagged. Every command-name pattern is
# prefixed with STMT_START; only the bare `>` / `>>` redirect operators
# remain unanchored (they can appear anywhere on a statement line).
WRITE_CMDS_RE='(>|>>'
WRITE_CMDS_RE+="|${STMT_START}tee\b"
WRITE_CMDS_RE+="|${STMT_START}(cp|mv|install|ln|dd)\b"
WRITE_CMDS_RE+="|${STMT_START}(chmod|chown|chattr)\b"
WRITE_CMDS_RE+="|${STMT_START}(truncate|rm|rmdir)\b"
WRITE_CMDS_RE+="|${STMT_START}(rsync|sponge)\b"
WRITE_CMDS_RE+="|${STMT_START}(unzip|bsdtar)\b"
WRITE_CMDS_RE+="|${STMT_START}tar\b[^|&;]*[[:space:]](-?[A-Za-z]*x|--extract|--delete)"
WRITE_CMDS_RE+="|${STMT_START}gawk\b[^|&;]*[[:space:]]-i[[:space:]]+inplace"
WRITE_CMDS_RE+="|${STMT_START}awk\b[^|&;]*[[:space:]]-i[[:space:]]+inplace"
WRITE_CMDS_RE+="|${STMT_START}find\b[^|&;]*[[:space:]]-(delete|exec[a-z]*)\b"
WRITE_CMDS_RE+="|${STMT_START}xargs\b[^|&;]*[[:space:]](rm|cp|mv|chmod|chown|truncate|install|ln|dd|tee|sed)\b"
WRITE_CMDS_RE+="|${STMT_START}git\b[^|&;]*[[:space:]](checkout|restore|reset|apply|clean|mv|rm)\b"
WRITE_CMDS_RE+="|${STMT_START}curl\b[^|&;]*[[:space:]](-o\b|-O\b|--output\b|--output-document\b)"
WRITE_CMDS_RE+="|${STMT_START}wget\b[^|&;]*[[:space:]](-O\b|--output-document\b)"
WRITE_CMDS_RE+="|${STMT_START}gpg\b[^|&;]*[[:space:]](-o\b|--output\b)"
WRITE_CMDS_RE+="|${STMT_START}openssl\b[^|&;]*[[:space:]]-out\b"
WRITE_CMDS_RE+="|${STMT_START}(python3?|node)\b"
WRITE_CMDS_RE+="|${STMT_START}sed\b[^|&;]*[[:space:]](-[A-Za-z]*i([[:space:]=.]|$)|--in-place([[:space:]=]|$))"
WRITE_CMDS_RE+="|${STMT_START}perl\b[^|&;]*[[:space:]](-[A-Za-z]*i([[:space:]=.]|$)|--in-place([[:space:]=]|$))"
WRITE_CMDS_RE+="|${STMT_START}ruby\b[^|&;]*[[:space:]](-[A-Za-z]*i([[:space:]=.]|$))"
WRITE_CMDS_RE+=')'

# Subset of WRITE_CMDS_RE for commands that operate on a directory tree rather
# than a single named file (so the protected-FILE regex won't catch them but a
# directory-prefix regex will). Same statement-start anchoring as WRITE_CMDS_RE.
TREE_CMDS_RE="(${STMT_START}find\b[^|&;]*[[:space:]]-(delete|exec[a-z]*)\b"
TREE_CMDS_RE+="|${STMT_START}tar\b[^|&;]*[[:space:]](-?[A-Za-z]*x|--extract|--delete)"
TREE_CMDS_RE+="|${STMT_START}unzip\b"
TREE_CMDS_RE+="|${STMT_START}rsync\b"
TREE_CMDS_RE+="|${STMT_START}rm\b[^|&;]*[[:space:]]-[A-Za-z]*[rR]"
TREE_CMDS_RE+=')'

# ============================================================================
# Block messages
# ============================================================================

block_zone() {
  printf 'path-guard: "%s" is outside the allowed directories.\n' "$1" >&2
  printf 'Allowed roots: %s, %s\n' "$PROJECT_DIR" "$CLAUDE_DIR" >&2
  exit 2
}

block_write() {
  local target="$1" reason="$2"

  # Repeat-suppression: after the first write-block per session, emit only the
  # one-liner header so the verbose scratch+mv workflow doesn't re-bill on
  # every later turn. The marker file lives in CLAUDE_SESSION_SCRATCH; tests
  # don't export it, so they always see the full message.
  local seen_file=""
  if [ -n "${CLAUDE_SESSION_SCRATCH:-}" ]; then
    seen_file="$CLAUDE_SESSION_SCRATCH/.path-guard-seen"
    if [ -f "$seen_file" ]; then
      printf 'path-guard: cannot write "%s" — %s\n' "$target" "$reason" >&2
      printf '(See earlier path-guard message this session for the scratch+mv workflow.)\n' >&2
      exit 2
    fi
  fi

  local scratch="${CLAUDE_SESSION_SCRATCH:-$PROJECT_DIR/${CLAUDE_SCRATCH_ROOT:-.scratch}}"
  # Repo-relative form of the scratch dir for the user-runnable mv command.
  # CLAUDE_SESSION_SCRATCH is only exported inside Claude's bash subprocess,
  # so a fresh terminal cannot expand it — the prompt must show a path that
  # works in any shell when run from $PROJECT_DIR.
  local scratch_rel="${scratch#$PROJECT_DIR/}"
  # Resolve the absolute target so the -x test below works regardless of
  # whether the caller passed a relative or absolute path. If the "target"
  # is a descriptive string (e.g. "command targeting a [protected] file"),
  # this just produces a non-existent path and the -x test falls through.
  local abs="$target"
  case "$abs" in
    /*) ;;
    *)  abs="$PROJECT_DIR/$abs" ;;
  esac
  printf 'path-guard: cannot write "%s" — %s\n' "$target" "$reason" >&2
  printf 'To proceed: write to %s/<basename>.new, show the diff, then ask:\n' "$scratch" >&2
  printf '  mv %s/<basename>.new <target>\n' "$scratch_rel" >&2
  printf '(Use the repo-relative path; $CLAUDE_SESSION_SCRATCH is not exported in the user'"'"'s shell.)\n' >&2
  if [ -x "$abs" ] && [ -f "$abs" ]; then
    printf 'Target is executable: also ask: chmod +x <target> (Write creates 0644).\n' >&2
  fi
  printf 'Do not retry.\n' >&2

  # Mark first-seen so the next block in this session takes the short path.
  [ -n "$seen_file" ] && touch "$seen_file" 2>/dev/null

  exit 2
}

block_read() {
  printf 'path-guard: reading "%s" is not allowed (matches a [secret] rule).\n' "$1" >&2
  exit 2
}

# ============================================================================
# Bash redirect/tee target capture
# ============================================================================

extract_targets() {
  local cmd="$1"
  printf '%s\n' "$cmd" | grep -oE '[0-9]*>>?[[:space:]]*/[^[:space:]|&;<>"'"'"'\\]+'   2>/dev/null | sed -E 's/^[0-9]*>>?[[:space:]]*//'
  printf '%s\n' "$cmd" | grep -oE '[0-9]*>>?[[:space:]]*~[^[:space:]|&;<>"'"'"'\\]*'   2>/dev/null | sed -E 's/^[0-9]*>>?[[:space:]]*//'
  printf '%s\n' "$cmd" | grep -oE '[0-9]*>>?[[:space:]]*"[^"]+"'                       2>/dev/null | sed -E 's/^[0-9]*>>?[[:space:]]*"//;s/"$//'
  printf '%s\n' "$cmd" | grep -oE "[0-9]*>>?[[:space:]]*'[^']+'"                       2>/dev/null | sed -E "s/^[0-9]*>>?[[:space:]]*'//;s/'\$//"
  printf '%s\n' "$cmd" | grep -oE '\btee\b([[:space:]]+-[a-zA-Z]+)*[[:space:]]+/[^[:space:]|&;<>"'"'"'\\]+'  2>/dev/null | grep -oE '/[^[:space:]|&;<>"'"'"'\\]+$' 2>/dev/null
  printf '%s\n' "$cmd" | grep -oE '\btee\b([[:space:]]+-[a-zA-Z]+)*[[:space:]]+~[^[:space:]|&;<>"'"'"'\\]*'  2>/dev/null | grep -oE '~[^[:space:]|&;<>"'"'"'\\]*$'  2>/dev/null
  printf '%s\n' "$cmd" | grep -oE '\btee\b([[:space:]]+-[a-zA-Z]+)*[[:space:]]+"[^"]+"'                      2>/dev/null | grep -oE '"[^"]+"$' 2>/dev/null | sed 's/^"//;s/"$//'
  printf '%s\n' "$cmd" | grep -oE "\btee\b([[:space:]]+-[a-zA-Z]+)*[[:space:]]+'[^']+'"                      2>/dev/null | grep -oE "'[^']+'\$" 2>/dev/null | sed "s/^'//;s/'\$//"
  return 0
}

# ============================================================================
# Tool dispatch
# ============================================================================

case "$TOOL_NAME" in
  Read)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    [ -z "$FILE_PATH" ] && exit 0
    case "$FILE_PATH" in
      /*) ABS_PATH="$FILE_PATH" ;;
      *)  ABS_PATH="$PROJECT_DIR/$FILE_PATH" ;;
    esac
    if is_secret "$ABS_PATH"; then
      block_read "$FILE_PATH"
    fi
    ;;

  Edit|Write|MultiEdit|NotebookEdit)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    [ -z "$FILE_PATH" ] && exit 0
    case "$FILE_PATH" in
      /*) ABS_PATH="$FILE_PATH" ;;
      *)  ABS_PATH="$PROJECT_DIR/$FILE_PATH" ;;
    esac
    if ! is_in_allowed_zone "$ABS_PATH"; then
      block_zone "$FILE_PATH"
    fi
    if is_write_blocked "$ABS_PATH"; then
      block_write "$FILE_PATH" "Matches a [secret] or [protected] rule. Ask the user to edit it manually."
    fi
    ;;

  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    [ -z "$COMMAND" ] && exit 0

    # Normalise newlines (including line-continuation `\<NL>`) to single spaces.
    # Without this, an attacker can split a write command and its target across
    # physical lines to defeat the per-line backstop greps.
    COMMAND_NORM=$(printf '%s' "$COMMAND" | tr '\n' ' ')

    # For backstop regex matching, additionally strip backslash, single-quote
    # and double-quote chars. Bash strips these at exec time, so they have no
    # effect on the resolved path, but they break the literal-substring regex.
    # Defeats `.claude\/x`, `".claude"/x`, `.cla""ude/x`, `'$PATH'`-style hiding.
    COMMAND_FLAT=$(printf '%s' "$COMMAND_NORM" | tr -d '\\"'"'")

    # Brace-expansion heuristic. Bash expands `{a,b}` at exec time but the
    # literal text breaks our positional regex. If any path-token contains a
    # `{…}` brace AND a write command appears on the same logical line, refuse
    # — the caller can rewrite using literal paths.
    if echo "$COMMAND_NORM" | grep -qE "$WRITE_CMDS_RE" 2>/dev/null \
    && echo "$COMMAND_NORM" | grep -qE '/[^/[:space:]"'"'"'|&;<>]*\{[^{}]*\}|\{[^{}]*\}[^/[:space:]"'"'"'|&;<>]*/' 2>/dev/null; then
      block_write "brace-expansion in a path adjacent to a write command" \
        "path-guard cannot statically resolve brace expansion in paths. Rewrite using literal paths."
    fi

    # Glob `*` / `?` in a path token combined with a write command targeting
    # a protected or secret directory. Bash will expand the glob to potentially
    # many files (including ones we'd block individually), so we refuse.
    if echo "$COMMAND_FLAT" | grep -qE "$WRITE_CMDS_RE" 2>/dev/null \
    && echo "$COMMAND_FLAT" | grep -qE '/[^/[:space:]|&;<>]*[*?]|[*?][^[:space:]|&;<>]*/' 2>/dev/null; then
      if [ -n "$PROTECTED_DIRS_RE" ] \
      && echo "$COMMAND_FLAT" | grep -qE "$PROTECTED_DIRS_RE" 2>/dev/null; then
        block_write "glob-expanded path adjacent to a [protected] directory" \
          "Cannot statically resolve glob '*' or '?' in a path that overlaps a protected directory. Use a literal file path."
      fi
      if [ -n "$SECRET_DIRS_RE" ] \
      && echo "$COMMAND_FLAT" | grep -qE "$SECRET_DIRS_RE" 2>/dev/null; then
        block_write "glob-expanded path adjacent to a [secret] directory" \
          "Cannot statically resolve glob '*' or '?' in a path that overlaps a secret directory."
      fi
    fi

    # Backstop: any write operator on the same line as a protected/secret
    # path mention is blocked, regardless of quoting/tilde/path construction.
    # Uses COMMAND_FLAT so backslash/quote splitting cannot evade the match.
    if [ -n "$PROTECTED_RE" ]; then
      if echo "$COMMAND_FLAT" | grep -qE "${WRITE_CMDS_RE}[^|&;]*${PROTECTED_RE}" 2>/dev/null \
      || echo "$COMMAND_FLAT" | grep -qE "${PROTECTED_RE}[^|&;]*${WRITE_CMDS_RE}" 2>/dev/null; then
        block_write "command targeting a [protected] file" \
          "This command appears to modify a [protected] file; ask the user to edit it manually."
      fi
    fi
    if [ -n "$SECRET_RE" ]; then
      if echo "$COMMAND_FLAT" | grep -qE "${WRITE_CMDS_RE}[^|&;]*${SECRET_RE}" 2>/dev/null \
      || echo "$COMMAND_FLAT" | grep -qE "${SECRET_RE}[^|&;]*${WRITE_CMDS_RE}" 2>/dev/null; then
        block_write "command targeting a [secret] file" \
          "This command appears to modify a [secret] file."
      fi
    fi

    # Tree-style commands (find -delete/-exec, tar -x, unzip, rsync, rm -r):
    # the file-level PROTECTED_RE only matches when the full path is named in
    # the command text. For tree operations the command names a directory
    # instead, so we additionally match against the directory-prefix regex.
    if echo "$COMMAND_FLAT" | grep -qE "$TREE_CMDS_RE" 2>/dev/null; then
      if [ -n "$PROTECTED_DIRS_RE" ] \
      && echo "$COMMAND_FLAT" | grep -qE "$PROTECTED_DIRS_RE" 2>/dev/null; then
        block_write "tree-walking command (find/tar/unzip/rsync/rm -r) targeting a [protected] directory" \
          "Cannot statically determine which files this command will affect. Use an explicit file path."
      fi
      if [ -n "$SECRET_DIRS_RE" ] \
      && echo "$COMMAND_FLAT" | grep -qE "$SECRET_DIRS_RE" 2>/dev/null; then
        block_write "tree-walking command (find/tar/unzip/rsync/rm -r) targeting a [secret] directory" \
          "Cannot statically determine which files this command will affect."
      fi
    fi

    # Pipe-spanning attack: `find /protected | xargs DESTRUCTIVE` or `... | rm`.
    # The plain backstop's `[^|&;]*` cannot cross a pipe, so the destructive
    # command on the right and the path mention on the left would not match
    # together. Allow pipes between PROTECTED_DIRS_RE and xargs+destructive.
    # Both the xargs form and the bare-command form are statement-anchored
    # (they must appear immediately after the pipe + optional whitespace) so
    # `… | echo "got-rm-result"` doesn't trigger.
    XARGS_DEST_RE="\bxargs\b[^|&;]*[[:space:]](rm|cp|mv|chmod|chown|truncate|install|ln|dd|tee|sed|sponge)\b"
    PIPE_TO_DEST_RE="\|[[:space:]]*(${XARGS_DEST_RE}|(rm|cp|mv|sponge)\b)"
    if [ -n "$PROTECTED_DIRS_RE" ] \
    && echo "$COMMAND_FLAT" | grep -qE "${PROTECTED_DIRS_RE}[^|&;]*${PIPE_TO_DEST_RE}" 2>/dev/null; then
      block_write "pipeline feeding a [protected] directory listing to a destructive command" \
        "Cannot statically determine which files will be affected. Use an explicit path."
    fi
    if [ -n "$SECRET_DIRS_RE" ] \
    && echo "$COMMAND_FLAT" | grep -qE "${SECRET_DIRS_RE}[^|&;]*${PIPE_TO_DEST_RE}" 2>/dev/null; then
      block_write "pipeline feeding a [secret] directory listing to a destructive command" \
        "Cannot statically determine which files will be affected."
    fi

    # Zone + per-target rule check on every captured redirect/tee target.
    # extract_targets sees COMMAND_NORM so line-continuation splits are joined.
    while IFS= read -r raw; do
      [ -z "$raw" ] && continue
      case "$raw" in
        '&'*) continue ;;
      esac
      if ! is_in_allowed_zone "$raw"; then
        block_zone "$raw"
      fi
      if is_write_blocked "$raw"; then
        block_write "$raw" "Writing to this file via shell bypasses the Edit tool check."
      fi
    done < <(extract_targets "$COMMAND_NORM" || true)
    ;;

  *) exit 0 ;;
esac

exit 0
