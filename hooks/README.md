# Claude Code hooks

All hooks live under `.claude/hooks/<name>/hook.sh` and are wired in `.claude/settings.json`.

## Execution order

Hooks within a matcher run left-to-right. Any hook that exits 2 blocks the tool call; subsequent hooks in the chain do not run.

### `PreToolUse: ""` (all tools)

1. **path-guard** — inspects tool name internally; acts on `Read`, `Edit`, `Write`, `NotebookEdit`, `Bash`

### `PreToolUse: Read`

1. **read-once** — warns when a file is already in context (unchanged since last read)

### `PreToolUse: Bash`

1. **bash-guard** — blocks dangerous shell patterns
2. **always-allow** — auto-approves whitelisted single commands (no permission prompt)
3. **read-guard** — blocks file-reading via text tools (`cat`, `head`, `tail`, `sed`, `awk`, `grep`, `sort`, `xxd`, …)

### `PostCompact`

1. **read-once** (`compact.sh`) — clears the read cache so re-reads are allowed after context compaction

---

## Hooks

### path-guard

**File:** `path-guard/hook.sh`  
**Applies to:** `Read`, `Edit`, `Write`, `NotebookEdit`, `Bash`  
**Cannot be disabled.**

Two layers of protection:

**Layer 1 — zone check:** restricts file operations to two allowed roots:
- `$CLAUDE_PROJECT_DIR` — the project tree
- `$HOME/.claude` — Claude Code user configuration

**Layer 2 — protected-file check:** blocks writes to specific files even within the allowed roots:
- `$CLAUDE_PROJECT_DIR/.claude/settings.json`, `settings.local.json`, `CLAUDE.md`
- `$CLAUDE_PROJECT_DIR/.claude/hooks/*/hook.sh`, `.../compact.sh` — the guard executables themselves
- `$HOME/.claude/settings.json`, `settings.local.json`, `CLAUDE.md`

Test files, READMEs, and other non-executable files inside the hooks directory are not protected.

**Read:** blocks access to any `.ssh` directory (any user's `~/.ssh`, `/home/*/.ssh`, `/root/.ssh`).

**Edit / Write / NotebookEdit:** zone check then protected-file check. Resolves `..` traversal via `realpath -m`.

**Bash:** absolute-path redirects (`>`, `>>`, `N>`) and `tee` commands are checked against both the zone and the protected-file list. Additionally, pattern-based checks catch relative-path redirects and tee to Claude config files (e.g. `> .claude/settings.json`). `/dev/null`, `/dev/stdout`, `/dev/stderr`, `/dev/stdin`, and `/dev/fd/*` are always allowed.

Tests: `path-guard/test.sh`

---

### bash-guard

**File:** `bash-guard/hook.sh`  
**Applies to:** `Bash`  
**Disable:** `BASH_GUARD_DISABLED=1`

Blocks a broad set of dangerous or irreversible shell operations. Key categories:

| Category | Examples |
|---|---|
| Mass deletion | `rm -rf /`, `find -delete`, `xargs rm` |
| Disk destruction | `dd of=/dev/sdX`, `mkfs`, `fdisk`, `wipefs` |
| Privilege escalation | `sudo`, `su -c`, `pkexec`, `doas` |
| Pipe to shell | `curl … | bash`, `bash <(curl …)` |
| Encoding bypass | `base64 -d | bash`, `xxd -r | sh` |
| Credential exposure | `env`, `export -p`, reading `.env`/`.pem`/`.key`/`.ssh/id_*` |
| Database destruction | `prisma db push`, `DROP DATABASE`, `TRUNCATE`, `dropdb`, `FLUSHALL` |
| Cloud infrastructure | `terraform destroy`, `kubectl delete namespace`, `aws s3 rm --recursive` |
| In-place file editing | `sed -i`, `perl -i`, `ruby -i` (bypasses file-guard checks) |
| Docker | `compose down -v`, `system prune`, host volume mounts (`-v /host:`) |
| Git | `push --force`, `filter-branch`, `clean -f` |
| Persistence | `crontab -e`, `launchctl load`, `systemctl enable` |

Custom rules can be added in `.bash-guard`:

```
allow: sudo          # whitelist a blocked pattern
deny: curl           # block all curl commands
```

Tests: none (external tool; see upstream).

---

### always-allow

**File:** `always-allow/hook.sh`  
**Applies to:** `Bash`  
**Disable:** `ALWAYS_ALLOW_DISABLED=1`

Auto-approves specific Bash commands without showing a permission prompt. Multi-command lines (containing `&&`, `||`, `;`, `|`, or newlines) are never auto-allowed regardless of any rule.

Config files (concatenated, in load order):

1. `always-allow/default.always-allow` — shipped defaults (e.g. hook test scripts)
2. `$HOME/.claude/.always-allow` — user defaults
3. `$CLAUDE_PROJECT_DIR/.always-allow` — project rules

Each file is a list of POSIX ERE patterns, one per line, grouped into named sections:

| Section | Eligible invocations |
|---|---|
| `[allow]` | foreground single-command only. Default section for unlabelled lines (preserves flat-list configs). |
| `[background]` | foreground **and** background single commands. Use sparingly: background processes can hide chained payloads inside a script. Reserve for trusted long-running launchers. |

Unknown section headers are silently ignored. `[bg]` is accepted as an alias for `[background]`.

Example project `.always-allow`:

```
[allow]
^(bash )?scripts/build[[:alnum:]_-]*\.sh
^(bash )?scripts/headless-chrome\.sh$
^(bash )?scripts/inspect\.sh.*
^(bash )?scripts/test\.sh($|[[:space:]])

[background]
^(bash )?scripts/run\.sh
```

When a command matches, the hook emits `{"decision": "allow"}` to stdout, bypassing the interactive permission prompt. Non-matches fall through to the permission system normally.

Tests: `always-allow/test.sh`

---

### read-guard

**File:** `read-guard/hook.sh`  
**Applies to:** `Bash`  
**Disable:** `READ_GUARD_DISABLED=1`

Blocks Bash commands that read file content using text-processing tools instead of the `Read` tool. Enforces the project rule that file reads must go through `Read` (which provides line numbers and respects hook checks).

**Redirect bypass:** commands whose stdout is redirected to a file (` > file` or ` >> file`) are allowed — the content goes to disk, not back to Claude. Stderr-only redirects (`2>`) are still blocked.

**Directory exclusions:** `read-guard/.read-guard` lists directory prefixes where the guard does not apply (one per line, `#` for comments). A command is exempted if it references any listed prefix as a path token (preceded by whitespace, `/`, `'`, `"`, `=`, or line start). Include the trailing slash. The hook additionally auto-exempts the scratch root from `$CLAUDE_SCRATCH_ROOT` (default `.scratch/`) so diagnostic dumps under the per-session scratch dir can always be inspected with shell tools.

Blocked patterns:

| Tool(s) | Condition |
|---|---|
| `cat`, `less`, `more`, `bat`, `strings`, `sort`, `tac`, `nl`, `od`, `xxd`, `hexdump` | reading a named file (not a plain stdin invocation) |
| `head`, `tail` | reading a named file |
| `sed` | any use without `-i` (in-place edit) |
| `awk` | any use |
| `grep`, `egrep`, `fgrep`, `rg`, `ag`, `cut` | invoked directly or after `;`/`&&`/`\|\|` (not as a pipeline filter after `\|`) |

Pipeline filters are allowed: `cmd | grep foo` passes through; `grep foo file` is blocked.

Tests: `read-guard/test.sh`

---

### read-once

**File:** `read-once/hook.sh`, `read-once/compact.sh`  
**Applies to:** `Read` (PreToolUse), PostCompact  
**Disable:** `READ_ONCE_DISABLED=1`

Tracks file reads within a session. When Claude re-reads a file that hasn't changed (same mtime) and the cache is fresh, the hook advises that the content is already in context and reports estimated token savings.

**Mode** (`READ_ONCE_MODE`):
- `warn` (default) — allows the re-read but attaches an advisory. Prevents Edit tool deadlock (Edit requires a prior Read to succeed) and parallel read cascade failures.
- `deny` — hard-blocks the re-read. Maximum token savings but breaks Edit if used aggressively.

**Diff mode** (`READ_ONCE_DIFF=1`) — when a file has changed since last read, sends only the unified diff instead of the full file. Falls back to a full re-read if the diff exceeds `READ_ONCE_DIFF_MAX` lines (default: 40).

**Compaction safety** — cache entries expire after `READ_ONCE_TTL` seconds (default: 7200). The `compact.sh` PostCompact hook clears the cache immediately when context compaction occurs.

Partial reads (with `offset` or `limit`) are never cached and always pass through.

Cache stored at `~/.claude/read-once/`.

Tests: `read-once/test.sh`
