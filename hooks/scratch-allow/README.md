# scratch-allow

PreToolUse hook. Auto-approves `Write`, `Edit`, and `MultiEdit` calls whose target lies inside the per-session scratch directory (`$CLAUDE_SESSION_SCRATCH`).

## Why

`path-guard` already permits writes inside the session scratch root (it sits inside the allowed project zone), but Claude Code's harness still prompts the user on the first write to each new file. The scratch+mv workflow described in `CLAUDE.md` runs many `Write` calls into scratch — one prompt per file is friction without security value. This hook short-circuits those prompts.

## Decision contract

| Tool | Target | Result |
|---|---|---|
| `Write` / `Edit` / `MultiEdit` | inside `$CLAUDE_SESSION_SCRATCH` (after `realpath -m`) | `permissionDecision: allow` |
| `Write` / `Edit` / `MultiEdit` | outside the scratch root | pass through silently (other hooks decide) |
| any other tool | — | pass through silently |

`path-guard` remains the security backstop: if the resolved target is outside the project zone or matches a `[secret]`/`[protected]` rule, path-guard blocks regardless of what this hook returns.

## Configuration

No config files. The boundary is the live env var `$CLAUDE_SESSION_SCRATCH` (populated by the `session-scratch` hook at SessionStart). If the env var is unset the hook passes through, leaving other hooks to decide.

## Env vars

| Var | Effect |
|---|---|
| `SCRATCH_ALLOW_DISABLED=1` | Short-circuits the hook at entry (exits 0, no decision). |
| `CLAUDE_SESSION_SCRATCH` | Required for the hook to fire. Set by `session-scratch` at SessionStart. |
| `CLAUDE_PROJECT_DIR` | Used to resolve relative `file_path` values. Falls back to `$(pwd)`. |

## Install

Same wiring as the other hooks. In `.claude/settings.json`, add the `PreToolUse` matcher for the write tools:

```json
{
  "matcher": "Write|Edit|MultiEdit",
  "hooks": [
    {
      "type": "command",
      "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/scratch-allow/hook.sh"
    }
  ]
}
```

The matcher list deliberately omits `NotebookEdit` — notebooks are out of scope for the scratch+mv workflow today, and the hook can be extended later if that changes.

## Failure modes

- `jq` missing from `$PATH` → emits a `[scratch-allow] jq not found` warning on stderr and exits 0 (same fail-open convention as `always-allow`).
- Symlink resolution: `realpath -m` follows the chain. A symlink in scratch pointing OUT of scratch is correctly classified as "not in scratch" and falls through. A symlink anywhere pointing IN to scratch is classified as "in scratch" and allows.
- Prefix collision: `<scratch>/foo` and `<scratch>-other/foo` both have `<scratch>` as a textual prefix, but the hook appends a `/` before matching so `<scratch>-other/foo` does NOT match.

## Files

- `hook.sh` — the hook
- `test.sh` — 14 unit tests
- `README.md` — this file
