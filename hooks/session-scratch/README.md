# session-scratch

Per-session scratch directories for Claude Code.

## Motivation

session-scratch exists for two reasons that compound:

**1. Concurrent sessions on the same repository clone.** Multiple Claude
Code sessions can run against the same project directory at once — one
in a terminal, another in a separate IDE window, a third spawned via
`claude --resume` to revisit a prior conversation, plus any subagents
each of those spawns. Without per-session scratch they all share a
single `scratch/` directory and collide:

- Both write `scratch/out.json` while inspecting different URLs and
  clobber each other's diagnostic dumps.
- Both write `scratch/commit-msg.txt` and one session's commit message
  overwrites the other's.
- Per-tool cache files (notably `read-once`'s) mix readings from
  independent context windows.

Per-session subdirectories under
`$CLAUDE_SCRATCH_ROOT/<session_id>/`, exposed as
`$CLAUDE_SESSION_SCRATCH` to every Bash tool call, keep each session's
state independent.

**2. Anchoring `read-once` via `read-guard`.** `read-once` only sees
the Read tool — shell-based file reads (`cat`, `grep`, `sed`, `awk`,
…) bypass it entirely. `read-guard` exists to close that gap: it
blocks the shell forms and forces the agent through the Read tool,
where `read-once` can then track every read and de-duplicate the
re-reads. The two hooks only deliver on that promise when `read-once`
has somewhere to keep its per-session cache:
`$CLAUDE_PROJECT_DIR/$CLAUDE_SCRATCH_ROOT/<session_id>/read-once/<agent>.jsonl`.
session-scratch creates that directory on `SessionStart`, exports the
variables that point at it, and removes it on `SessionEnd`. Without
session-scratch, `read-once`'s cache would either be shared across
sessions (false hits) or have to invent its own ad-hoc lifecycle. With
it, the three hooks compose into a single coherent "what is already in
this session's context window" model that survives concurrent use.

## How it works

`hook.sh` is a dispatcher invoked on both `SessionStart` and `SessionEnd`.

**SessionStart** (any source — startup, resume, clear, compact):

- Creates `$CLAUDE_PROJECT_DIR/scratch/<session_id>/`.
- Writes `export CLAUDE_SESSION_ID=...` and
  `export CLAUDE_SESSION_SCRATCH=...` to `$CLAUDE_ENV_FILE`. The harness
  sources that file so all subsequent Bash tool calls in this session
  have those variables.
- Sweeps any entry directly under `scratch/` older than 7 days
  (crashed-session dirs, legacy pre-per-session files).

**SessionEnd** (any source — clear, resume, logout, exit):

- Removes `scratch/<session_id>/`.

## Why both SessionStart and SessionEnd

`/clear` and `claude --resume` issue a *new* `session_id`. SessionEnd
fires for the *ending* session (cleans up the old dir), then
SessionStart fires for the new session (creates the new dir). The two
hooks together keep scratch tidy across every lifecycle transition the
harness exposes.

The 7-day GC on SessionStart is the failsafe for the only path neither
event covers: process abort (Ctrl-C, kill -9, crash).

## Env vars

| Variable                   | Set by                             | Value                                                       |
|----------------------------|------------------------------------|-------------------------------------------------------------|
| `CLAUDE_SCRATCH_ROOT`      | `.claude/settings.json` `env`      | Project-relative directory name. Default: `.scratch`.       |
| `CLAUDE_SESSION_SCRATCH`   | this hook on SessionStart          | `$CLAUDE_PROJECT_DIR/$CLAUDE_SCRATCH_ROOT/$session_id`.     |

The full directory is `<project>/<scratch-root>/<session_id>/`. Concurrent
sessions each get their own subdirectory so writes never collide.

`CLAUDE_SCRATCH_ROOT` is read with a fallback of `.scratch`, so the hook
suite works even before you've configured the `env` block; setting it in
`settings.json` only matters if you want the directory name to differ.

## Usage

In CLAUDE.md and scripts, refer to scratch paths as
`$CLAUDE_SESSION_SCRATCH/<name>` rather than `scratch/<name>`. The
variable resolves to the current session's absolute scratch path.

Example:

```sh
curl -s "$URL" > "$CLAUDE_SESSION_SCRATCH/out.json"
```

Use `$CLAUDE_SESSION_SCRATCH` (not `$CLAUDE_SCRATCH_ROOT`) for all
within-session scratch writes — curl-to-file dumps, commit-message files
for `git commit -F`, generated `.new` files when path-guard blocks a
write, etc. The variable is exported only inside Claude's own bash
subprocess; if you need a path to hand to the user for them to run in
their own shell, write it repo-relative (e.g.
`.scratch/<session_id>/foo.new`).

## Other hooks that use these variables

- **read-once** stores its per-session cache at
  `$CLAUDE_SCRATCH_ROOT/$session_id/read-once/` so the cache is
  reclaimed automatically when the session ends.
- **path-guard**'s "write to scratch and ask the user to `mv`" workflow
  points the agent at `$CLAUDE_SESSION_SCRATCH/<basename>.new`.
- **read-guard** auto-exempts the scratch root (`$CLAUDE_SCRATCH_ROOT/`)
  from its "use Read tool" rule so diagnostic dumps under the per-session
  scratch dir can be inspected with shell tools.

## CLAUDE.md suggestions

Copy the following into your project's CLAUDE.md so agents use the
per-session scratch directory consistently. The patterns assume the
`session-scratch` hook is registered on SessionStart and SessionEnd.

````markdown
**Per-session scratch.** Each session gets its own scratch subdirectory at
`$CLAUDE_SCRATCH_ROOT/<session_id>/`, exported as `$CLAUDE_SESSION_SCRATCH`
by the `session-scratch` hook. `CLAUDE_SCRATCH_ROOT` is set in
`.claude/settings.json` (default: `.scratch`). Always write scratch files
under `$CLAUDE_SESSION_SCRATCH/`, never directly under the scratch root —
concurrent sessions would otherwise race on identical filenames. The
per-session directory is removed on SessionEnd; entries older than 7 days
at the top level of `$CLAUDE_SCRATCH_ROOT/` are swept on SessionStart.

**Repo-relative paths.** Never write to `/tmp`. All scratch files, output
dirs, and test artefacts go inside the repo tree — scratch files
specifically go under `$CLAUDE_SESSION_SCRATCH/`.

**curl to file then Read.** Never pipe curl output to the terminal or to
another command. Always redirect to a scratch file under
`$CLAUDE_SESSION_SCRATCH/` and then use the Read tool to inspect the
result. Pattern: `curl -s <url> > "$CLAUDE_SESSION_SCRATCH/out.json"`
then Read `$CLAUDE_SESSION_SCRATCH/out.json`.

**Commit messages go in a per-session scratch file.** Always write the
commit message to `$CLAUDE_SESSION_SCRATCH/commit-msg.txt` and run
`git commit -F "$CLAUDE_SESSION_SCRATCH/commit-msg.txt"`. Inline
`-m "..."` or HEREDOC bodies risk being read by `path-guard`'s backstop
as the command itself when the message describes destructive operations
or protected paths.

**Hand-off to the user's own shell.** `$CLAUDE_SESSION_SCRATCH` is only
exported inside Claude's bash subprocess; a fresh terminal does not have
it. When emitting a `mv` / `cat` / etc. for the user to run, expand the
variable to the repo-relative form (e.g. `.scratch/<session_id>/foo.new`)
so the command is copy-pasteable in any shell.
````
