# path-guard

The choke point between Claude Code and the filesystem.

A PreToolUse hook that runs for **every** tool call and refuses operations
that escape the allowed zone, target a `[secret]` file, or write to a
`[protected]` file. It is the last line of defence — if path-guard does
not block, the operation reaches the filesystem.

The hook handles:

- **Read** — blocked if the path matches a `[secret]` rule.
- **Edit / Write / MultiEdit / NotebookEdit** — zone check first, then
  `[secret]` / `[protected]` rules.
- **Bash** — zone check on redirect / `tee` targets, plus a backstop
  that blocks any write operator on the same line as a `[secret]` or
  `[protected]` path mention.

## Zones

Writes outside these roots are always blocked, regardless of rules:

- `$CLAUDE_PROJECT_DIR` (the current project tree)
- `$HOME/.claude` (Claude Code user configuration)
- `/dev/null` and friends (read-only escape hatches for redirection)

## Rule sections

Two sections inside each layered config file:

- **`[secret]`** — block Read **and** Write. The agent should not see the
  contents nor modify them.
- **`[protected]`** — block Write only. The agent may read the file (for
  inspection) but must ask the user to make changes.

When path-guard blocks a write, the error message tells the agent to put
the new content in `$CLAUDE_SESSION_SCRATCH/<basename>.new` and prompt the
user to `mv` it into place. The same workflow applies to any
shell-driven write the backstop refuses.

## Configuration

Layered files, all concatenated:

| File | Purpose |
| --- | --- |
| `default.path-guard` (shipped) | Defaults — SSH keys, cloud creds, env files, cert extensions, `.git/`, hook scripts, etc. |
| `~/.claude/.path-guard` | Per-user rules across all projects. |
| `$CLAUDE_PROJECT_DIR/.path-guard` | Project-specific rules. |

Pattern syntax (gitignore-flavoured):

| Token | Meaning |
| --- | --- |
| `*` | Any chars within a path segment (no `/`). |
| `**` | Any number of path segments. |
| `?` | One char (no `/`). |
| `[abc]` | Char class. |
| `~` | Leading tilde expands to `$HOME`. |
| `/foo/bar` | Leading `/` anchors to the filesystem root. |
| `foo/bar` | No leading `/` matches as basename or path-suffix. |
| `dir/**` | Also matches the directory itself, not just its contents. |

There is no `!` negation. To drop a default rule, comment it out in
`default.path-guard` rather than add an override.

Example project `.path-guard`:

```ini
[secret]

**/secrets/*.toml
**/*.credentials.json

[protected]

deployment/k8s/production/**
migrations/**
schema.sql
```

The shipped `default.path-guard` documents the full syntax inline.

## Env vars

| Variable | Default | Purpose |
| --- | --- | --- |
| `PATH_GUARD_HOOK_DIR` | (auto) | Override the hook's own directory (for tests). |
| `CLAUDE_PROJECT_DIR` | (set by Claude Code) | Allowed-zone anchor and project-rule lookup. |
| `CLAUDE_SESSION_SCRATCH` | (set by `session-scratch` hook) | Path quoted in the workflow message when a write is blocked. |

## Security log

[`HARDENING.md`](HARDENING.md) tracks every adversarial pass on the hook,
the bypass classes each pass closed, and limitations that remain deferred.
The adversarial probes live in [`test-jailbreak.sh`](test-jailbreak.sh),
chained from the regular test suite.

## Test

```sh
bash test.sh   # runs unit tests + the jailbreak probes
```
