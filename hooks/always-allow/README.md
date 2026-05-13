# always-allow

Suppresses the Claude Code permission prompt for Bash commands that match a
configured regex allowlist.

A PreToolUse hook for the Bash tool. When the input command matches any of
the configured ERE patterns, the hook emits `{"decision": "allow"}` and the
command runs without a prompt. Non-matching commands fall through to the
normal permission flow (and any other PreToolUse hooks downstream).

## What it never auto-allows

Regardless of the configured patterns, the hook explicitly *does not*
auto-allow:

- Commands containing `&&`, `||`, `;`, `|`, or newlines — multi-statement
  chains can smuggle a dangerous payload after a benign prefix.
- Background commands (`tool_input.run_in_background = true`) — same risk
  in a different form.

These always fall through to the prompt or to other guards (`bash-guard`,
`path-guard`).

## Configuration

Layered config files, all concatenated:

| File | Purpose |
| --- | --- |
| `default.always-allow` (shipped) | Defaults that apply everywhere. |
| `~/.claude/.always-allow` | Per-user defaults across all projects. |
| `$CLAUDE_PROJECT_DIR/.always-allow` | Project-specific patterns. |

Each line is a POSIX ERE pattern. Blank lines and `#` comments are ignored.
A command is auto-allowed if it matches any line. There is no `!` negation —
to drop a default rule, comment it out in `default.always-allow` rather than
add an override.

Example project `.always-allow`:

```regex
# Project build scripts that this agent runs frequently.
^(bash )?scripts/build[[:alnum:]_-]*\.sh
^(bash )?scripts/run\.sh
^npm run (test|lint|typecheck)$
```

## Env vars

| Variable | Default | Purpose |
| --- | --- | --- |
| `ALWAYS_ALLOW_DISABLED` | `0` | `1` disables the hook entirely. |
| `ALWAYS_ALLOW_LOG` | `0` | `1` logs allow/deny decisions to stderr. |
| `ALWAYS_ALLOW_HOOK_DIR` | (auto) | Override the hook's own directory (for tests). |

## Test

```sh
bash test.sh
```
