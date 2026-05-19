# cd-guard

Blocks top-level `cd` in Bash tool calls.

A PreToolUse hook for the Bash tool. The Bash tool's working directory persists across tool calls, and several other hooks (`path-guard`, `read-guard`, `session-scratch`, `always-allow`) derive paths from `$CLAUDE_PROJECT_DIR` and/or `$PWD`. A stray top-level `cd` into a subdir biases every later command — relative paths resolve elsewhere, `git status` shows the wrong tree, scripts pick up the wrong config layer — and the agent typically does not notice the drift.

This hook enforces the convention "stay at the repo root; no `cd`" that the megarepo's root `CLAUDE.md` documents.

## What it blocks

Top-level `cd` — that is, a `cd` invocation that runs in the parent shell and so leaves cwd changed for subsequent tool calls. Statement-anchored regex; substrings inside argument text do not trigger.

Blocked shapes:

```
cd /tmp                     # at start of command
  cd /tmp                   # leading whitespace
echo hi; cd /tmp            # after `;`
true && cd /tmp             # after `&&` (or single `&`)
false || cd /tmp            # after `||` (or single `|`)
cd                          # no argument (cd to $HOME)
cd -                        # cd back
```

## What it allows

`cd` inside a subshell or substitution — the cwd change is scoped and doesn't leak:

```
( cd /tmp && ls )                       # subshell
$(cd /tmp && pwd)                       # command substitution
`cd /tmp && pwd`                        # backtick substitution
bash -c 'cd /tmp && ls'                 # one-shot subshell via bash -c
{ cd /tmp; ls; }                        # brace group (also tolerated)
```

`cd` mentioned inside argument text (a string literal that happens to contain "cd"):

```
echo "did cd to dir"
echo 'run cd to /tmp'
./cd-tool --help
```

The canonical alternatives the block message points at:

```
git -C <subdir> <command>               # for git ops
ls /absolute/path                       # absolute paths
cat .gitignore                          # repo-relative paths
bash -c 'cd <dir> && <cmd>'             # one-shot cwd change
```

## Configuration

Env vars:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CD_GUARD_DISABLED` | `0` | `1` disables the hook entirely. |

There is no config file. The rule is binary: enforce or don't.

## Failure mode

If `jq` is not on `PATH`, the hook prints a one-line stderr warning and exits 0 (fail-open) — same convention as `always-allow` and `scratch-allow`. `path-guard` remains the security backstop; `cd-guard`'s scope is convention enforcement, not a hardening layer.

## Install

`scripts/install-hooks.sh` (run from the claude-tools root) creates the `.claude/hooks/cd-guard` symlink for every consumer project. Then register the hook in that project's `.claude/settings.json` under `PreToolUse` with a Bash matcher:

```json
{
  "matcher": "Bash",
  "hooks": [
    {
      "type": "command",
      "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/cd-guard/hook.sh"
    }
  ]
}
```

## Test

```
bash test.sh
```

## CLAUDE.md suggestion

The root CLAUDE.md should already say "Stay at the repo root; no `cd`. Use `git -C <subdir>` for git operations and absolute or repo-relative paths everywhere else." cd-guard is the enforcement layer for that rule.
