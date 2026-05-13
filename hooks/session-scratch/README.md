# session-scratch

Per-session scratch directories for Claude Code.

Without this hook, all Claude Code sessions running in the same project
share `scratch/`. Concurrent sessions race on identical filenames (e.g.
both write `scratch/out.json` while inspecting different URLs).

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

## Usage

In CLAUDE.md and scripts, refer to scratch paths as
`$CLAUDE_SESSION_SCRATCH/<name>` rather than `scratch/<name>`. The
variable resolves to the current session's absolute scratch path.

Example:

```sh
curl -s "$URL" > "$CLAUDE_SESSION_SCRATCH/out.json"
```
