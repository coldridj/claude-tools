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
user to `mv` it into place. The message is five lines: a `path-guard:
cannot write …` header (with the rule reason inline), a `To proceed:`
workflow line, the `mv` command, a parenthetical explaining why the
repo-relative path is shown instead of `$CLAUDE_SESSION_SCRATCH`, and a
final `Do not retry.`. If the target is executable, an extra
`chmod +x` line is appended. The same workflow applies to any
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

# Block both Read and Write on credential files anywhere in the project.
**/secrets/*.toml
**/*.credentials.json

[protected]

# Block Write only — files can still be inspected with the Read tool.
deployment/k8s/production/**
migrations/**
schema.sql

# The shipped default matches `.claude/hooks/**/hook.sh`, but path-guard
# resolves through symlinks via realpath. `install.sh` writes these
# realpath mirrors so a symlinked hook stays write-blocked.
git_modules/claude-tools/hooks/**/hook.sh
git_modules/claude-tools/hooks/**/compact.sh
```

Example user-wide `~/.claude/.path-guard`:

```ini
[secret]

# Personal credential stores not covered by the shipped defaults.
~/.config/op/**
~/.config/rclone/rclone.conf
~/Vault/**

[protected]

# Personal dotfiles you never want an agent to edit accidentally.
~/.bashrc
~/.zshrc
~/.gitconfig
```

The shipped `default.path-guard` documents the full syntax inline and
ships sensible defaults for SSH keys, AWS/GCP/Azure credentials,
`/etc/shadow`, cert/key extensions, `.env*`, `.git/**`, and so on.
Override at the user or project layer rather than editing the default
file in the submodule.

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

## CLAUDE.md suggestions

Copy the following into your project's CLAUDE.md so an agent knows how
to react when path-guard blocks a write. Without this rule the agent
typically retries with workarounds (escaping, alternate paths, etc.) —
which is exactly the failure mode path-guard's bash-backstop is built to
defeat, but it wastes a turn each time.

````markdown
**Write-blocked files: scratch + prompt.** When `path-guard` blocks a
write (the hook prints `path-guard: cannot write "..." — <reason>`), do
not retry or attempt to bypass. Instead:

1. Write the intended new content to `$CLAUDE_SESSION_SCRATCH/<basename>.new`
   (or another descriptive scratch path under `$CLAUDE_SESSION_SCRATCH/`).
2. Show the diff against the original.
3. Prompt the user to move the file with a
   `mv <repo-relative-scratch-path>/<basename>.new <target>` command they
   can run from the repo root. **Always use the repo-relative scratch
   path (e.g. `.scratch/<session_id>/<basename>.new`), not
   `$CLAUDE_SESSION_SCRATCH`** — that variable is only exported inside
   Claude's bash subprocess; a fresh terminal does not have it.

This applies to both single-file edits (CLAUDE.md, `.claude/settings.json`,
hook scripts) and shell-driven writes that the backstop refuses. Never
try to defeat the protection — its job is to make these edits a
human-in-the-loop step.
````

If your project also commits with `path-guard` active, pair the rule
above with this one — the backstop will otherwise read the commit
message as the command and block the commit itself:

````markdown
**Commit messages go in a per-session scratch file.** Always write the
commit message to `$CLAUDE_SESSION_SCRATCH/commit-msg.txt` and run
`git commit -F "$CLAUDE_SESSION_SCRATCH/commit-msg.txt"`. Inline
`-m "..."` or HEREDOC bodies are blocked by the backstop when the
message describes destructive commands or protected paths.
````
