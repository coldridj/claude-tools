# read-once

Stop Claude Code from re-reading files it already has in context.

A PreToolUse hook that tracks file reads within a session. When Claude tries to re-read a file that hasn't changed, the hook tells Claude the content is already in context. Saves ~2000+ tokens per prevented re-read.

By default, read-once uses **warn mode**: it allows the read but attaches an advisory message. This prevents the Edit tool deadlock (Edit requires a prior Read) and parallel read cascade failures. Set `READ_ONCE_MODE=deny` for hard blocking if you want maximum token savings and don't use Edit frequently.

## Key behaviour

- **Deterministic invalidation.** `READ_ONCE_TTL` defaults to `0` (off). The
  per-session cache is cleared by `PostCompact`, by `SessionStart`
  matcher=`compact` (belt-and-suspenders), and by `session_id` rotation on
  `/clear` / `--resume`. A positive `READ_ONCE_TTL` remains available as a
  failsafe for environments where `PostCompact` might not fire reliably.
- **Single hook entry-point.** `hook.sh` dispatches on `hook_event_name` —
  `PreToolUse` runs the read-tracking logic, `PostCompact` /
  `SessionStart(matcher=compact)` clear the cache. There is no longer a
  separate `compact.sh`; route all three events at `hook.sh`.
- **Per-session scratch storage.** Cache files live at
  `$CLAUDE_PROJECT_DIR/$CLAUDE_SCRATCH_ROOT/<session_id>/read-once/<agent>.jsonl`
  (where `$CLAUDE_SCRATCH_ROOT` is set in `.claude/settings.json`, default
  `.scratch`). The `session-scratch` SessionEnd hook reclaims the directory
  automatically. Cross-session stats persist at `~/.claude/read-once/stats.jsonl`.
- **Subagent isolation.** The hook reads `agent_id` from the payload and
  writes a separate cache file per agent (`main.jsonl` for the parent,
  `<agent_id>.jsonl` per subagent). Subagents share the parent's
  `session_id` but have independent context windows, so without this the
  parent's reads would produce false "already in context" hits in subagents.

## How it works

1. Hook intercepts every `Read` tool call
2. Partial reads (with `offset` or `limit`) always pass through — only full-file reads are cached
3. Checks a session-scoped cache: has this file been read before?
4. Compares file mtime — if unchanged, advises Claude the content is already in context
5. In warn mode (default): allows the read with advisory. In deny mode: blocks the read entirely
6. If the file changed since last read, allows it through (or shows just the diff — see below)
7. Cache invalidation is deterministic: cleared on `PostCompact`, on
   `SessionStart(matcher=compact)`, and on `session_id` rotation. A
   positive `READ_ONCE_TTL` (default `0`) is available as a failsafe.

### Diff mode (opt-in)

When you're iterating on a file — read it, edit it, read it again — Claude already has the old version in context. With diff mode enabled, read-once shows only what changed instead of the full file. A 3-line change in a 200-line file costs ~30 tokens instead of ~2000.

Enable with:

```sh
export READ_ONCE_DIFF=1
```

When a re-read is blocked with a diff, Claude sees:

```
read-once: app.py changed since last read. You already have the previous
version in context. Here are only the changes (saving ~1850 tokens):

--- previous
+++ current
@@ -45,3 +45,3 @@
-    return None
+    return default_value

Apply this diff mentally to your cached version of the file.
```

If the diff is too large (>40 lines by default), read-once falls back to allowing a full re-read. Configure the threshold with `READ_ONCE_DIFF_MAX`.

### What Claude sees

When a re-read is intercepted, Claude receives (in warn mode):

```
read-once: schema.rb (~2,340 tokens) already in context (read 3m ago, unchanged).
Cache cleared on /compact, /clear, or resume. Session savings: ~4,680 tokens.
```

Claude then proceeds without the redundant read. No loss of information — the
file content is still in the context window from the first read.

### Compaction safety

Claude Code compacts the context window during long sessions, dropping older
content. A file read earlier in the session may no longer be in the working
context.

read-once handles this two ways:

1. **PostCompact and SessionStart(compact)** (default): the same `hook.sh`
   is registered for the `PostCompact` event and for `SessionStart` with
   `matcher: "compact"`. Either firing clears the per-session cache. This
   is the deterministic invalidation path; nothing depends on wall-clock
   time.
2. **TTL failsafe** (off by default): set `READ_ONCE_TTL` to a positive
   number of seconds to additionally expire entries after that age, in
   case `PostCompact` does not fire in your environment.

The per-session cache directory is also reclaimed by the `session-scratch`
SessionEnd hook, and a new `session_id` (from `/clear` / `--resume`) routes
the cache to a fresh directory automatically.

## Stats

Cross-session stats accumulate at `~/.claude/read-once/stats.jsonl`. Each
line is a JSON event: hits (`"event":"hit"`), diff-mode interceptions
(`"event":"diff"`), expirations (`"event":"expired"`), and compaction
clears (`"event":"compact"`). Aggregate with `jq` for ad-hoc reports —
e.g. total tokens saved:

```sh
jq -r 'select(.event=="hit" or .event=="diff") | .tokens_saved' \
  ~/.claude/read-once/stats.jsonl | paste -sd+ - | bc
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `READ_ONCE_MODE` | `warn` | `warn` allows reads with advisory message. `deny` blocks reads entirely. Warn mode prevents Edit tool deadlock and parallel read cascade failures. |
| `READ_ONCE_TTL` | `0` | Failsafe TTL in seconds. `0` (default) means hook-driven invalidation only (`PostCompact` / `SessionStart(compact)` / `session_id` rotation). Set to a positive value to additionally expire entries after that age. |
| `READ_ONCE_DIFF` | `0` | Set to `1` to show only diffs when files change (instead of full re-read). |
| `READ_ONCE_DIFF_MAX` | `40` | Max diff lines before falling back to full re-read. |
| `READ_ONCE_DISABLED` | `0` | Set to `1` to disable the hook entirely. |

## Requirements

- `jq` (for JSON parsing)
- `bash` 4+
- `python3` (optional, for diff mode JSON escaping)
- Claude Code with hooks support

## How much does it save?

Claude Code re-reads files more than you'd think. Common patterns:
- Reading a file, editing it, then reading it again to verify
- Re-reading config files across different parts of a task
- Reading the same file in subagents that share a session

Each blocked re-read saves the full file token cost (including the ~70%
overhead from line numbers in `cat -n` format). Aggregate
`~/.claude/read-once/stats.jsonl` with `jq` for actual savings.

## FAQ

**The Edit tool says "File has not been read yet" even though I already read it.**
This happens in deny mode (`READ_ONCE_MODE=deny`). Claude Code's Edit tool
requires a successful Read before it will edit a file. When read-once
blocks the Read, Edit thinks the file was never read. The fix: use the
default warn mode (`READ_ONCE_MODE=warn`), which allows reads with an
advisory instead of blocking them.

**Won't this break after context compaction?**
`PostCompact` and `SessionStart(matcher=compact)` both route at `hook.sh`,
which clears the per-session cache. With `READ_ONCE_TTL=0` (default),
that is the only invalidation. Set `READ_ONCE_TTL` to a positive value
as an additional failsafe if your environment does not fire
`PostCompact` reliably.

**Claude Code reads small chunks, not whole files — does this help?**
Partial reads with `offset` or `limit` are never cached. They always pass
through. read-once only deduplicates full-file reads where the entire
file is requested again.

**Isn't there a good reason Claude re-reads files?**
Yes — when the file changed, or when context compacted. read-once only
intercepts re-reads when the file hasn't changed (same mtime) and the
cache is current. Changed files always pass through. With diff mode
enabled (`READ_ONCE_DIFF=1`), changed files show just the delta instead
of the full content.
