# claude-tools

A reusable suite of Claude Code hooks (and, eventually, skills) intended to be
vendored into a project as a git submodule. Each hook lives in its own
directory under `hooks/`; an `install.sh` at the repo root wires them into the
parent project's `.claude/hooks/` directory as per-hook symlinks.

> **⚠ Mostly AI-generated and unaudited.** The bulk of the code here — hooks,
> tests, scripts, and most of this README — was written by Claude Code with
> light human review. The hardening passes are real (see
> `hooks/path-guard/HARDENING.md` and `hooks/bash-guard/HARDENING.md` for the
> jailbreak probes and what they close), but the underlying code has not been
> independently security-audited. Treat it as **defence in depth, not a
> trusted boundary**. Review hook scripts before installing them, and never
> rely on these guards as your only protection against an agent doing
> something destructive. The Unlicense (below) disclaims all warranty —
> that disclaimer is doing real work here.

## Layout

```
.
├── hooks/
│   ├── always-allow/      # Auto-approves Bash patterns from .always-allow
│   ├── bash-guard/        # Blocks dangerous shell commands
│   ├── path-guard/        # Read/Write zone + per-file write protection
│   ├── read-guard/        # Steers file reads through the Read tool
│   ├── read-once/         # Suppresses redundant re-reads within a session
│   ├── session-scratch/   # Per-session $CLAUDE_SESSION_SCRATCH directory
│   └── README.md          # Per-hook reference (matchers, env vars, behaviour)
├── install.sh             # Symlink installer (this file documents how to run it)
└── LICENSE
```

See [`hooks/README.md`](hooks/README.md) for per-hook configuration, env vars,
and the execution order Claude Code uses when several hooks share a matcher.

### Per-hook docs

| Hook | README | Notes |
| --- | --- | --- |
| always-allow | [`hooks/always-allow/README.md`](hooks/always-allow/README.md) | Regex allowlist suppressing the permission prompt for matched Bash commands. |
| bash-guard | [`hooks/bash-guard/README.md`](hooks/bash-guard/README.md) | Blocks dangerous shell commands. Security hardening log: [`HARDENING.md`](hooks/bash-guard/HARDENING.md). |
| path-guard | [`hooks/path-guard/README.md`](hooks/path-guard/README.md) | Zone enforcement + `[secret]`/`[protected]` rules across every tool. Security hardening log: [`HARDENING.md`](hooks/path-guard/HARDENING.md). |
| read-guard | [`hooks/read-guard/README.md`](hooks/read-guard/README.md) | Steers file-read shell commands through the Read tool. |
| read-once | [`hooks/read-once/README.md`](hooks/read-once/README.md) | Read-tracking, deterministic invalidation, diff mode. |
| session-scratch | [`hooks/session-scratch/README.md`](hooks/session-scratch/README.md) | Per-session `$CLAUDE_SESSION_SCRATCH` lifecycle and 7-day GC. |

## Installation

### 1. Add as a submodule

From the parent project's repo root:

```bash
git submodule add <repository path> git_modules/claude-tools
git -C git_modules/claude-tools fetch --tags origin
git -C git_modules/claude-tools checkout latest
git add git_modules/claude-tools
```

The `latest` tag is force-updated to every fresh github-mirror snapshot by
`scripts/push-github-mirror.sh` (run from the pre-push hook), so pinning to
it gives you a stable ref that always tracks the most recent published
snapshot. To pull updates later:

```bash
git -C git_modules/claude-tools fetch --tags --force origin
git -C git_modules/claude-tools checkout latest
git add git_modules/claude-tools
git commit -m "claude-tools: bump to latest"
```

The submodule can live at any path inside the superproject — `install.sh`
auto-detects its own location relative to the parent and uses that when
generating project-local config.

### 2. Run the installer

```bash
bash git_modules/claude-tools/install.sh           # prompt per hook
bash git_modules/claude-tools/install.sh --all     # install everything, no prompts
bash git_modules/claude-tools/install.sh --dry-run # report what would change
bash git_modules/claude-tools/install.sh --force   # overwrite real files at target
bash git_modules/claude-tools/install.sh --help
```

Interactive prompts accept: `Y` install / `n` skip / `a` install all remaining /
`q` quit. The default (empty answer) is `Y`.

For each entry in `hooks/`, the script creates a symlink at
`<super>/.claude/hooks/<name>` pointing back into the submodule with a
repo-relative target (so the link survives a project move). `.claude/hooks/`
itself remains a regular directory — you can keep project-local hooks alongside
the symlinked ones.

Existing symlinks at the target are silently updated when they point at the
wrong place. Real files/directories at the target require `--force` to be
replaced, so project-local hooks that happen to share a name with one in
claude-tools are not destroyed.

### 3. path-guard side-effect

When `path-guard` is among the items installed (or already correctly
symlinked), the script also writes — or appends to — a `<super>/.path-guard`
file with the following `[protected]` entries:

```
<submodule-path>/hooks/**/hook.sh
<submodule-path>/hooks/**/compact.sh
```

`path-guard` resolves symlinks via `realpath -m`, so the shipped pattern
`.claude/hooks/**/hook.sh` no longer matches a write whose real target is the
hook script inside the submodule. The project-local `.path-guard` re-asserts
protection using the realpath form. The patterns are detected from the
submodule's actual location, so they work whether claude-tools lives at
`git_modules/claude-tools`, `vendor/claude-tools`, or anywhere else.

The append is idempotent — re-running `install.sh` will not duplicate the
entries.

### 4. Wire the hooks + scratch env into `.claude/settings.json`

The installer only creates symlinks; you still need to register each hook in
`.claude/settings.json` under the appropriate matcher and (optionally) set
`CLAUDE_SCRATCH_ROOT` in the `env` block. A complete example wiring every hook
in this repo:

```json
{
  "env": {
    "CLAUDE_SCRATCH_ROOT": ".scratch"
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/path-guard/hook.sh" }
        ]
      },
      {
        "matcher": "Read",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/read-once/hook.sh" }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/bash-guard/hook.sh" },
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/always-allow/hook.sh" },
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/read-guard/hook.sh" }
        ]
      }
    ],
    "PostCompact": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/read-once/hook.sh" }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/session-scratch/hook.sh", "statusMessage": "Preparing per-session scratch" }
        ]
      },
      {
        "matcher": "compact",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/read-once/hook.sh" }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/session-scratch/hook.sh" }
        ]
      }
    ]
  }
}
```

What each matcher block does:

| Event             | Matcher    | Hooks (left-to-right)                                | Purpose                                                                |
|-------------------|------------|------------------------------------------------------|------------------------------------------------------------------------|
| `PreToolUse`      | `""`       | path-guard                                           | Zone + per-file write protection on every tool call.                   |
| `PreToolUse`      | `Read`     | read-once                                            | Suppress redundant re-reads of unchanged files.                        |
| `PreToolUse`      | `Bash`     | bash-guard → always-allow → read-guard               | Block dangerous shell, auto-approve known commands, steer file reads.  |
| `PostCompact`     | `""`       | read-once/hook.sh                                    | Clear the read cache after context compaction.                         |
| `SessionStart`    | `""`       | session-scratch                                      | mkdir + export `$CLAUDE_SESSION_SCRATCH`; sweep 7-day-stale entries.    |
| `SessionStart`    | `compact`  | read-once/hook.sh                                    | Belt-and-suspenders cache clear if `PostCompact` didn't fire.          |
| `SessionEnd`      | `""`       | session-scratch                                      | Remove this session's scratch dir.                                     |

Order within a single matcher matters: hooks run left-to-right and any hook
that exits 2 short-circuits the rest of the chain.

## Per-session scratch

The `session-scratch` hook gives every Claude Code session its own scratch
subdirectory and exposes it through two environment variables:

| Variable                   | Set by                             | Value                                                       |
|----------------------------|------------------------------------|-------------------------------------------------------------|
| `CLAUDE_SCRATCH_ROOT`      | `.claude/settings.json` `env`      | Project-relative directory name. Default: `.scratch`.       |
| `CLAUDE_SESSION_SCRATCH`   | `session-scratch` SessionStart     | `$CLAUDE_PROJECT_DIR/$CLAUDE_SCRATCH_ROOT/$session_id`.     |

The full directory is `<project>/<scratch-root>/<session_id>/`. Concurrent
sessions each get their own subdirectory so writes never collide.

Lifecycle:

- **SessionStart** — `mkdir -p` the per-session dir; export both variables via
  the harness env file; sweep entries older than 7 days at the top level of
  `$CLAUDE_SCRATCH_ROOT/` (covers crashed sessions that never reached
  SessionEnd).
- **SessionEnd** — `rm -rf` the per-session dir.

Use `$CLAUDE_SESSION_SCRATCH` (not `$CLAUDE_SCRATCH_ROOT`) for all
within-session scratch writes — curl-to-file dumps, commit-message files for
`git commit -F`, generated `.new` files when path-guard blocks a write, etc.
The variable is exported only inside Claude's own bash subprocess; if you
need a path to hand to the user for them to run in their own shell, write
it repo-relative (e.g. `.scratch/<session_id>/foo.new`).

`CLAUDE_SCRATCH_ROOT` is read with a fallback of `.scratch`, so the hook
suite works even before you've configured the `env` block; setting it in
`settings.json` only matters if you want the directory name to differ.

Other hooks that respect `CLAUDE_SCRATCH_ROOT`:

- **read-once** stores its per-session cache at
  `$CLAUDE_SCRATCH_ROOT/$session_id/read-once/` so the cache is reclaimed
  automatically when the session ends.
- **path-guard**'s "write to scratch and ask the user to `mv`" workflow points
  at `$CLAUDE_SESSION_SCRATCH/<basename>.new`.

## Configuration

Each hook (other than session-scratch) loads layered configuration: shipped
defaults, then user-wide overrides under `$HOME/.claude/.<hook>`, then
project-local overrides under `$CLAUDE_PROJECT_DIR/.<hook>`. All three files
concatenate, so layered files **add to** the rule set — there is no `!`
negation. To drop a default rule, comment it out in the shipped file.

| Hook           | Project-root file | Purpose                                                              |
|----------------|-------------------|----------------------------------------------------------------------|
| `always-allow` | `.always-allow`   | ERE patterns auto-approved for Bash (e.g. project build scripts).    |
| `path-guard`   | `.path-guard`     | `[secret]` / `[protected]` rules in addition to shipped defaults.    |
| `read-guard`   | `.read-guard`     | Path prefixes exempt from the "use Read tool" guard.                 |

### path-guard

`.path-guard` files have up to two sections — `[secret]` (block both Read and
Write) and `[protected]` (block Write only). Patterns use a gitignore-flavoured
glob:

| Token         | Meaning                                                            |
|---------------|--------------------------------------------------------------------|
| `*`           | Any characters within a path segment (no `/`).                     |
| `**`          | Any number of path segments.                                       |
| `?`           | One character (no `/`).                                            |
| `[abc]`       | Character class.                                                   |
| `~`           | Leading tilde expands to `$HOME`.                                  |
| `/foo/bar`    | Leading `/` anchors to filesystem root.                            |
| `foo/bar`     | No leading `/` matches as basename or path-suffix.                 |
| `dir/**`      | Also matches the directory itself, not just its contents.          |

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

# The shipped pattern matches .claude/hooks/**/hook.sh, but path-guard
# resolves through symlinks via realpath -m. install.sh writes these
# mirrors so the realpath of a symlinked hook stays write-blocked.
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

The shipped `hooks/path-guard/default.path-guard` documents the full pattern
syntax inline and ships sensible defaults for SSH keys, AWS/GCP/Azure
credentials, `/etc/shadow`, certificate/key extensions, `.env*`, and so on —
override at the user or project layer rather than editing the default file in
the submodule.

### always-allow

`.always-allow` files are flat lists of POSIX ERE patterns. A Bash command is
auto-approved if it matches any entry. Multi-command lines (`&&`, `||`, `;`,
`|`, newlines) and background commands are never auto-approved.

Example project `.always-allow`:

```regex
# Project build scripts that this agent runs frequently.
^(bash )?scripts/build[[:alnum:]_-]*\.sh
^(bash )?scripts/run\.sh
^npm run (test|lint|typecheck)$
```

### read-guard

`.read-guard` files list directory prefixes where the "use Read tool" guard
does not apply. Include the trailing `/`. read-guard additionally auto-exempts
`$CLAUDE_SCRATCH_ROOT/` (default `.scratch/`) so diagnostic dumps under the
session scratch dir can always be inspected with shell tools.

```
build/output/
docs/dumps/
```

## Updating

If you pinned to the `latest` tag at install time:

```bash
git -C git_modules/claude-tools fetch --tags --force origin
git -C git_modules/claude-tools checkout latest
git add git_modules/claude-tools
git commit -m "claude-tools: bump to latest"
```

The `--force` on the tag fetch is needed because `latest` is force-updated
every push, and local git treats tags as immutable by default.

Or to track main directly:

```bash
git -C git_modules/claude-tools pull origin main
git add git_modules/claude-tools
git commit -m "claude-tools: bump submodule"
```

Re-run `install.sh` after a pull if a new hook has been added upstream.

## Credits

- **read-once** and **bash-guard** are forked from / inspired by
  [Bande-a-Bonnot/Boucle-framework](https://github.com/Bande-a-Bonnot/Boucle-framework).
  The versions here are adapted for project-local conventions (per-session
  scratch storage, deterministic invalidation, subagent isolation) — see
  `hooks/read-once/README.md` for the specific divergences.
- **path-guard**, **read-guard**, **always-allow**, and **session-scratch** are
  original to claude-tools.

## License

Released into the public domain under [the Unlicense](https://unlicense.org/).
In short: you may copy, modify, redistribute, sell, or build on this software
for any purpose without permission or attribution. There is **no warranty**:
the software is provided as-is, and the authors disclaim all liability for
anything that happens when you run it.

Full text in `LICENSE`.
