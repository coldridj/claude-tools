#!/bin/bash
# cd-guard: PreToolUse hook — block top-level `cd` in Bash tool calls.
#
# Why this exists
# ---------------
# The Bash tool's working directory persists across tool calls. Several
# hooks (path-guard, read-guard, session-scratch, always-allow) derive
# paths from $CLAUDE_PROJECT_DIR and/or $PWD. A stray top-level `cd` into
# a subdir biases every subsequent command — relative paths resolve
# elsewhere, `git status` shows the wrong tree, scripts pick up the wrong
# config layer — and the agent typically does not notice the drift.
#
# The project rule (root CLAUDE.md, "Shell and tooling — Never `cd` at
# the top level") covers the convention; this hook enforces it.
#
# Blocked shapes (statement-anchored, so substrings like `echo "did cd"`
# do not trigger):
#   cd <dir>                # at start of command
#   <cmd>; cd <dir>         # after `;`
#   <cmd> && cd <dir>       # after `&&` (or `&`)
#   <cmd> || cd <dir>       # after `||` (or `|`)
#
# Allowed shapes (the cd does not affect the parent shell):
#   bash -c 'cd <dir> && <cmd>'   # one-shot subshell
#   ( cd <dir> ; <cmd> )           # explicit subshell
#   $( cd <dir> ; <cmd> )          # command substitution
#   `cd <dir> ; pwd`               # backtick substitution
#   echo "did cd to dir"           # cd inside argument text
#   git -C <dir> <cmd>             # the canonical alternative
#
# Override (rare): set CD_GUARD_DISABLED=1.
#
# Output: on block, prints a stderr message and exits 2. The message
# points at `git -C <dir>` and `bash -c 'cd X && cmd'` as alternatives.

set -euo pipefail

if [ "${CD_GUARD_DISABLED:-0}" = "1" ]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[cd-guard] jq not found in PATH — fail-open, no enforcement this call" >&2
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$COMMAND" ] && exit 0

# Collapse newlines (incl. `\<NL>` line continuations) to spaces, so a cd
# split across physical lines still matches the anchored regex below.
COMMAND_NORM=$(printf '%s' "$COMMAND" | tr '\n' ' ')

# Statement-start anchor: cd must appear as the first token of a logical
# statement — start-of-line (with optional leading whitespace) or after
# `;` / `&` / `|` (covering single and doubled forms).
#
# Deliberately NOT in the anchor: `(`, `{`, backtick — those open
# subshells / command substitutions / brace groups where cd is harmless
# (it doesn't leak to the parent shell's cwd). Quoted forms like
# `bash -c 'cd X'` lose the `cd` in a non-statement-start position
# (preceded by `-c ` or `'`) and don't match.
ANCHOR='(^[[:space:]]*|[;&|][[:space:]]*)'

if echo "$COMMAND_NORM" | grep -qE "${ANCHOR}cd([[:space:]]|\$)" 2>/dev/null; then
  cat >&2 <<EOF
cd-guard: top-level \`cd\` is blocked.

The Bash tool's cwd persists across tool calls; a top-level cd biases
every later command that derives paths from \$CLAUDE_PROJECT_DIR or \$PWD.
Use one of:

  - \`git -C <subdir> <command>\`           for git operations
  - absolute paths or repo-relative paths    for everything else
  - \`bash -c 'cd <dir> && <command>'\`     for one-shot cwd changes
                                             (subshell, doesn't leak)

Override (rare): set CD_GUARD_DISABLED=1 in the env.

Do not retry with an equivalent command.
EOF
  exit 2
fi

exit 0
