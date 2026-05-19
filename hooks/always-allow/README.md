# always-allow

Suppresses the Claude Code permission prompt for Bash commands that match a
configured regex allowlist.

A PreToolUse hook for the Bash tool. When the input command matches any of
the configured ERE patterns, the hook emits `{"decision": "allow"}` and the
command runs without a prompt. Non-matching commands fall through to the
normal permission flow (and any other PreToolUse hooks downstream).

## What it never auto-allows

Regardless of the configured patterns, the hook explicitly *does not*
auto-allow commands containing `&&`, `||`, `;`, or newlines — multi-
statement chains can smuggle a dangerous payload after a benign prefix.
These always fall through to the prompt or to other guards
(`bash-guard`, `path-guard`).

A single `|` is conditionally allowed: an allowlisted base command may
be piped into one or more read-only filters from a fixed whitelist
(see [Safe pipe filters](#safe-pipe-filters)). Filters that can write a
file (`tee`, `sponge`, `sed -i`, `awk -i inplace`) are deliberately
excluded — those still fall through.

### Safe pipe filters

The hook ships with a hardcoded list of binaries that take stdin and
write stdout, with no flag that can write a file: `head`, `tail`, `wc`,
`tr`, `cut`, `sort`, `uniq`, `nl`, `rev`, `fold`, `column`, `jq`, `yq`,
`grep`, `egrep`, `fgrep`, `rg`. An allowlisted command followed by a
chain of these filters is auto-allowed:

```
bash scripts/test.sh 2>&1 | tail -20        # ✓ tail is safe
cmd | grep foo | wc -l                       # ✓ grep+wc both safe
cmd | head > out.txt                         # ✗ redirect in filter
cmd | tee log                                # ✗ tee writes a file
cmd | sed -i s/x/y/ a                        # ✗ sed not in list
cmd | xargs rm                               # ✗ xargs not in list
```

Each filter segment must (a) have its first token in the whitelist as
a bare name (no `/path/to/head`, no `$VAR`, no `` `cmd` ``) and (b)
contain no `>` / `>>`. Override the list at runtime with
`ALWAYS_ALLOW_SAFE_PIPE_FILTERS=<space-separated names>`.

Background commands (`tool_input.run_in_background = true`) are auto-
allowed **only** when they match a pattern in the `[background]` section
(see below). Patterns in the default `[allow]` section never match a
background invocation, even if the command text would otherwise.

## Configuration

Layered config files, all concatenated:

| File | Purpose |
| --- | --- |
| `default.always-allow` (shipped) | Defaults that apply everywhere. |
| `~/.claude/.always-allow` | Per-user defaults across all projects. |
| `$CLAUDE_PROJECT_DIR/.always-allow` | Project-specific patterns. |

Each line is a POSIX ERE pattern. Blank lines and `#` comments are
ignored. A command is auto-allowed if it matches any line in a section
the invocation is eligible for. There is no `!` negation — to drop a
default rule, comment it out in `default.always-allow` rather than add
an override.

### Sections

Patterns are grouped into named sections. Two are recognised:

| Section | Eligible invocations |
| --- | --- |
| `[allow]` | Foreground single-command only. **Default section** for any unlabeled lines, so existing flat-list configs keep working unchanged. |
| `[background]` | Foreground **and** background single commands. Use sparingly: a background process can hide chained payloads inside a script. Reserve for trusted long-running launchers (dev servers, watchers, file daemons). |

`[bg]` is accepted as an alias for `[background]`. Unknown section
headers are silently skipped (the patterns under them never match).
Section headers must be lowercase and on their own line — `[BACKGROUND]`
is rejected by the strict `^\[([a-z]+)\]$` parser.

Example project `.always-allow`:

```ini
[allow]
# Project build scripts that this agent runs frequently.
^(bash )?scripts/build[[:alnum:]_-]*\.sh
^npm run (test|lint|typecheck)$

[background]
# Long-running launchers — auto-allowed in both fg and bg.
^(bash )?scripts/run\.sh
^npm run dev$
```

Flat configs (no section headers) still work — every line routes to the
implicit `[allow]` section:

```regex
# Equivalent to a single [allow] section.
^npm test$
^pytest( |$)
```

## Env vars

| Variable | Default | Purpose |
| --- | --- | --- |
| `ALWAYS_ALLOW_DISABLED` | `0` | `1` disables the hook entirely. |
| `ALWAYS_ALLOW_LOG` | `0` | `1` logs allow/deny decisions to stderr. |
| `ALWAYS_ALLOW_HOOK_DIR` | (auto) | Override the hook's own directory (for tests). |
| `ALWAYS_ALLOW_SAFE_PIPE_FILTERS` | (built-in list) | Space-separated override of the safe-pipe filter whitelist. |

## Test

```sh
bash test.sh
```

## CLAUDE.md suggestions

always-allow needs no runtime guidance — it operates silently. The one
project-level convention worth recording is *which* operations are
considered safe enough to add to `.always-allow` in the first place:

````markdown
**Auto-allowed commands live in `.always-allow`.** Project commands the
agent runs frequently (build scripts, `npm test`, `pytest`, etc.) belong
in `$CLAUDE_PROJECT_DIR/.always-allow` under an `[allow]` section so the
permission prompt does not fire on every invocation. Long-running
launchers that need to be auto-allowed in the background as well
(`run_in_background: true`) belong under `[background]` instead — be
sparing here, since a background script can hide chained payloads.
Anything destructive or anything that touches secrets must stay out of
this file entirely. The `always-allow` hook itself never auto-allows
commands containing `&&`, `||`, `;`, or newlines regardless of section,
but a loose entry still grants single-statement variants and pipes
into a read-only filter (head/tail/wc/grep/jq/…).
````
