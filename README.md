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

## Configuration

Each hook documents its own config file, env vars, and behaviour in its
README (linked from the [Per-hook docs](#per-hook-docs) table above).
Three of the hooks use a layered config file at the project root:

| Hook           | Project file     | Documented in                                              |
|----------------|------------------|------------------------------------------------------------|
| `always-allow` | `.always-allow`  | [`hooks/always-allow/README.md`](hooks/always-allow/README.md) |
| `path-guard`   | `.path-guard`    | [`hooks/path-guard/README.md`](hooks/path-guard/README.md)     |
| `read-guard`   | `.read-guard`    | [`hooks/read-guard/README.md`](hooks/read-guard/README.md)     |

Each is loaded as: shipped defaults → `$HOME/.claude/.<hook>` (user-wide
overrides) → `$CLAUDE_PROJECT_DIR/.<hook>` (project overrides). All three
files concatenate, so layered files **add to** the rule set — there is
no `!` negation. To drop a default rule, comment it out in the shipped
file.

The per-session-scratch env vars (`CLAUDE_SCRATCH_ROOT`,
`CLAUDE_SESSION_SCRATCH`), their lifecycle, and the hooks that consume
them are documented in
[`hooks/session-scratch/README.md`](hooks/session-scratch/README.md).

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
