# read-guard

Steers Bash file-read commands through Claude Code's native `Read` tool.

A PreToolUse hook for the Bash tool that blocks shell commands which read
file content (`cat`, `head`, `tail`, `sed`, `awk`, `grep`, `cut`, `xxd`,
`od`, `bat`, `strings`, etc.) when those tools target a named file rather
than acting as a pipeline filter. The Read tool is preferred because it:

- returns a structured, reviewable view with line numbers
- respects `path-guard`'s `[secret]` rules
- de-duplicates re-reads via `read-once`

## What it allows

read-guard is deliberately permissive about pipeline use; only direct
file-read forms are blocked.

| Form | Outcome |
| --- | --- |
| `cat file` / `head file` / `sed pat file` | **block** (use Read) |
| `cmd \| grep pat` / `cmd \| sed ...` | allow (grep / sed as a pipeline filter) |
| `cmd > file` / `cmd >> file` | allow (writing, not reading) |
| `sed -i ... file` | allow (file-write — `bash-guard` handles that) |
| `cat ./scratch/dump.json` | allow if `./scratch/` matches an exclusion |

Anchors that trigger the block are start-of-line, `;`, `&&`, `||` —
specifically NOT `|`, so anything after a pipe stays free.

## Configuration

Layered files, all concatenated:

| File | Purpose |
| --- | --- |
| `default.read-guard` (shipped) | Empty by default. |
| `~/.claude/.read-guard` | Per-user exclusions. |
| `$CLAUDE_PROJECT_DIR/.read-guard` | Project exclusions. |

Each line is a path-prefix exclusion. If the command contains any
configured prefix as a path token (preceded by a path-boundary char —
whitespace, `/`, `'`, `"`, `=`, or start of line), the guard does not
apply. Include a trailing `/` to mean "this directory".

Example project `.read-guard`:

```
build/output/
docs/dumps/
```

In addition to configured exclusions, the hook auto-exempts
`$CLAUDE_SCRATCH_ROOT/` (default `.scratch/`) so diagnostic dumps under
the per-session scratch directory can always be inspected with shell
tools.

## Env vars

| Variable | Default | Purpose |
| --- | --- | --- |
| `READ_GUARD_DISABLED` | `0` | `1` disables the hook entirely. |
| `READ_GUARD_HOOK_DIR` | (auto) | Override the hook's own directory (for tests). |
| `CLAUDE_SCRATCH_ROOT` | `.scratch` | Auto-exempted from the guard. |

## Test

```sh
bash test.sh
```

## CLAUDE.md suggestions

Copy the following into your project's CLAUDE.md so the agent reaches
for the Read tool by default. Without an explicit instruction the agent
often falls back to `cat` / `head` / `grep` for reading, which
read-guard then has to bounce on every attempt.

````markdown
**Read files.** Always use the Read tool, not bash commands like `cat`,
`head`, `tail`, `sed`, `awk`, `grep`, `cut`, `xxd`, `bat`, `strings`.
`read-guard` blocks these.

**curl to file then Read.** Never pipe curl output to the terminal or
to another command. Always redirect to a scratch file under
`$CLAUDE_SESSION_SCRATCH/` and then use the Read tool to inspect the
result. Pattern: `curl -s <url> > "$CLAUDE_SESSION_SCRATCH/out.json"`
then Read `$CLAUDE_SESSION_SCRATCH/out.json`.
````

If your project has output dirs (e.g. `build/output/`) that the agent
needs to inspect with shell tools, list them in
`$CLAUDE_PROJECT_DIR/.read-guard` rather than in CLAUDE.md — the guard
will then pass those paths through automatically.
