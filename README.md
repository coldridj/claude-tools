# claude-tools

A reusable suite of Claude Code hooks (and, eventually, skills) intended to be
vendored into a project as a git submodule. Each hook lives in its own
directory under `hooks/`; an `install.sh` at the repo root wires them into the
parent project's `.claude/hooks/` directory as per-hook symlinks.

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

See `hooks/README.md` for per-hook configuration, env vars, and the execution
order Claude Code uses when several hooks share a matcher.

## Installation

### 1. Add as a submodule

From the parent project's repo root:

```bash
git submodule add ssh://git@forgejo.dev.vekter.uk:2222/jack/claude-tools.git \
    git_modules/claude-tools
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

### 4. Wire the hooks in `.claude/settings.json`

The installer only creates symlinks; you still need to register each hook in
`.claude/settings.json` under the appropriate matcher. See `hooks/README.md`
for the recommended execution order; a minimal `settings.json` looks like:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "",     "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/path-guard/hook.sh" }] },
      { "matcher": "Read", "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/read-once/hook.sh" }] },
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/bash-guard/hook.sh" },
        { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/always-allow/hook.sh" },
        { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/read-guard/hook.sh" }
      ]}
    ],
    "PostCompact":  [{ "matcher": "",        "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/read-once/compact.sh" }] }],
    "SessionStart": [
      { "matcher": "",        "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/session-scratch/hook.sh" }] },
      { "matcher": "compact", "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/read-once/compact.sh" }] }
    ],
    "SessionEnd":   [{ "matcher": "",        "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/session-scratch/hook.sh" }] }]
  }
}
```

## Project-local config

Several hooks load layered configuration: shipped defaults, then
`$HOME/.claude/.<hook-name>`, then `$CLAUDE_PROJECT_DIR/.<hook-name>`. Put
project-specific entries at the project root, not in the shipped defaults:

| Hook        | Project-root file | Purpose                                                              |
|-------------|-------------------|----------------------------------------------------------------------|
| always-allow| `.always-allow`   | ERE patterns auto-approved for Bash (e.g. project build scripts).    |
| path-guard  | `.path-guard`     | `[secret]` / `[protected]` rules in addition to shipped defaults.    |
| read-guard  | `.read-guard`     | Path prefixes exempt from the "use Read tool" guard.                 |

The shipped `default.<hook-name>` files inside `hooks/<name>/` are kept free of
project-specific entries.

## Updating

```bash
git -C git_modules/claude-tools pull origin main
git add git_modules/claude-tools
git commit -m "claude-tools: bump submodule"
```

Re-run `install.sh` after a pull if a new hook has been added upstream.

## License

See `LICENSE`.
