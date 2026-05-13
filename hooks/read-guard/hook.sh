#!/usr/bin/env bash
# read-guard: PreToolUse hook — blocks Bash commands that read file content
# using text-processing tools (sed, awk, cat, head, tail) instead of the
# dedicated Read tool.
#
# The Read tool is always the right choice for reading files because it provides
# a structured, reviewable view with line numbers and respects file-guard rules.
#
# Config files (concatenated, in load order):
#   1. .claude/hooks/read-guard/default.read-guard  (shipped with the hook)
#   2. $HOME/.claude/.read-guard                    (user defaults)
#   3. $CLAUDE_PROJECT_DIR/.read-guard              (project rules)
#
# Each file is a flat list of path-prefix exclusions. The guard does not apply
# to a command that references any listed entry as a path token (preceded by a
# path-boundary char: whitespace, /, ', ", =, or start of line). Comments begin
# with # and run to end of line.
#
# In addition to the config files, the scratch root from $CLAUDE_SCRATCH_ROOT
# (default ".scratch") is exempted automatically — diagnostic dumps under the
# per-session scratch directory can always be inspected with shell tools.
#
# Disabled by setting READ_GUARD_DISABLED=1.

set -euo pipefail

if [ "${READ_GUARD_DISABLED:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [ -z "$COMMAND" ]; then
  exit 0
fi

block() {
  printf 'read-guard: %s\n' "$1" >&2
  printf 'Suggestion: %s\n' "$2" >&2
  exit 2
}

# If stdout is redirected to a file the content goes to disk, not back to Claude — allow it.
# Matches ` > file` and ` >> file` but not `2>` (stderr-only redirect).
if echo "$COMMAND" | grep -qE '[[:space:]]>>?[[:space:]]' 2>/dev/null; then
  exit 0
fi

# ============================================================================
# Config loader
# ============================================================================

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
HOOK_DIR="${READ_GUARD_HOOK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

EXCLUSIONS=()

# Auto-exempt the scratch root (from $CLAUDE_SCRATCH_ROOT env var) so dumps
# captured by curl/inspect/etc. under the per-session scratch dir can be
# inspected with shell tools without disabling the guard.
SCRATCH_NAME="${CLAUDE_SCRATCH_ROOT:-.scratch}"
# Strip any trailing slash, then add one (we want "<name>/").
SCRATCH_NAME="${SCRATCH_NAME%/}"
[ -n "$SCRATCH_NAME" ] && EXCLUSIONS+=("${SCRATCH_NAME}/")

load_config() {
  local file="$1" raw entry
  [ -f "$file" ] || return 0
  while IFS= read -r raw || [ -n "$raw" ]; do
    entry="${raw%%#*}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ -z "$entry" ] && continue
    EXCLUSIONS+=("$entry")
  done < "$file"
}

load_config "$HOOK_DIR/default.read-guard"
load_config "$HOME/.claude/.read-guard"
load_config "$PROJECT_DIR/.read-guard"

# Config-driven exclusions: if the command references any excluded path token,
# the guard does not apply.
for entry in "${EXCLUSIONS[@]+"${EXCLUSIONS[@]}"}"; do
  pattern=$(printf '%s' "$entry" | sed 's/[][\\.*^$+?(){}|/]/\\&/g')
  if printf '%s' "$COMMAND" | grep -qE "(^|[[:space:]/'\"=])${pattern}" 2>/dev/null; then
    exit 0
  fi
done

# cat/less/more/bat/strings/sort/tac/nl/od/xxd/hexdump used to read a file (not stdin)
# Matches: cat file, cat file | ..., cat -n file — but not plain `cat` (stdin)
if echo "$COMMAND" | grep -qE '(^|;[[:space:]]*|&&[[:space:]]*|\|\|[[:space:]]*)(cat|less|more|bat|strings|tac|nl|od|xxd|hexdump|sort)\s+(-[a-zA-Z]+\s+)?[^|&;>[:space:]]' 2>/dev/null; then
  block \
    "cat/less/more/bat/strings/sort/tac/nl/od/xxd/hexdump used to read a file. Use the Read tool instead." \
    "Replace with the Read tool, which provides structured line-numbered output."
fi

# head / tail reading a named file
if echo "$COMMAND" | grep -qE '(^|;[[:space:]]*|&&[[:space:]]*|\|\|[[:space:]]*)(head|tail)\s+(-[a-zA-Z0-9]+\s+)*[^|&;>[:space:]-]' 2>/dev/null; then
  block \
    "head/tail used to read a file. Use the Read tool with offset/limit instead." \
    "Read tool accepts 'offset' and 'limit' parameters to read specific line ranges."
fi

# sed used to read/extract (without -i in-place flag — that's already caught by bash-guard)
if echo "$COMMAND" | grep -qE '(^|;[[:space:]]*|&&[[:space:]]*|\|\|[[:space:]]*)sed\s+' 2>/dev/null; then
  if ! echo "$COMMAND" | grep -qE 'sed\s+(-[A-Za-z]*i|-i[^[:space:]]*)' 2>/dev/null; then
    block \
      "sed used to process file content. Use the Read tool to read files." \
      "Use the Read tool with offset/limit to read specific ranges, then process in your response."
  fi
fi

# awk reading a file (awk pattern file or awk -F... file)
if echo "$COMMAND" | grep -qE "(^|;[[:space:]]*|&&[[:space:]]*|\|\|[[:space:]]*)awk\s+" 2>/dev/null; then
  block \
    "awk used to process file content. Use the Read tool to read files." \
    "Use the Read tool to read the file, then reference specific lines in your response."
fi

# grep/rg/ag/cut invoked directly (not as a pipeline filter after |).
# Pipeline filters are allowed: `cmd | grep foo` is fine, but `grep foo file` is not.
# Anchor excludes `|` so `| grep` passes through; `;`, `&&`, `||` still block.
if echo "$COMMAND" | grep -qE '(^|;[[:space:]]*|&&[[:space:]]*|\|\|[[:space:]]*)(grep|egrep|fgrep|rg|ag|cut)[[:space:]]+' 2>/dev/null; then
  block \
    "grep/rg/ag/cut used to read file content directly. Use the Read tool instead." \
    "Read the file with the Read tool, then search or filter within your context."
fi

exit 0
