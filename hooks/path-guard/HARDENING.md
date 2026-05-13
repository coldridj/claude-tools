# path-guard hardening log

A chronological record of every hardening pass on the `path-guard`
PreToolUse hook, the bypass classes each pass closed, and the limitations
that remain deferred. New passes append a section at the bottom; do not
edit prior entries (they describe state at the time, not current behavior).

## Why this exists

`path-guard` is the last line of defense between Claude Code and the
filesystem. It runs synchronously before any Edit/Write/Read/Bash tool
call and can refuse the operation by exiting non-zero. Because it is the
choke point, every bypass is a high-severity bug: an attacker who finds
one can edit `.claude/settings.json`, the hook scripts themselves, or
read `.ssh/id_rsa`. Hardening proceeds adversarially — probes go into
`test-jailbreak.sh` first, then the hook is patched until they all hold.

## Threat model

- **In scope:** an LLM agent (Claude) issuing Edit/Write/Read/Bash tool
  calls. Adversarial input arrives as the tool's `tool_input` JSON. The
  attacker controls the entire command string for Bash and the
  `file_path` for the file tools.
- **Out of scope:** kernel-level escapes, race conditions between the
  hook firing and the tool executing, attacks via tools the hook does
  not see (e.g. MCP server tools that aren't routed through PreToolUse),
  and indirect execution where the visible command is benign and the
  destructive payload arrives at runtime (`base64 -d | bash`, fetched
  scripts, sourced files). The last class is `bash-guard`'s domain.
- **Trust boundary:** anything in `$CLAUDE_PROJECT_DIR` or
  `$HOME/.claude` is the working zone. The `[secret]` and `[protected]`
  rule sections carve out specific files within (or outside) those zones
  that need stricter handling.

## Rule sections

- `[secret]`     — block Read **and** Write. The agent should not see the
  contents nor modify them.
- `[protected]`  — block Write only. The agent may read for inspection
  but must ask the human to make changes.

Rules are concatenated from three files (default → user → project) so
later layers can extend but cannot override (no `!` negation).

## Pass 1 — initial hook (commit `f243250`)

**Coverage**
- Edit, Write, NotebookEdit blocked outside `$CLAUDE_PROJECT_DIR` and
  `$HOME/.claude`.
- Bash redirect (`>`, `>>`) and `tee` targets zone-checked.
- Read of any `.ssh` directory blocked.

**Known gaps at the time** — quoted/tilde redirects not captured,
non-redirect writes (`cp`, `sed -i`) not detected, only a hardcoded
shortlist of secret files.

## Pass 2 — zone + protected, merge config-guard (commit `39deeb6`)

Added a "protected files" check on top of the zone check: settings.json
files, CLAUDE.md, and hook executables. Folded the separate
`config-guard` hook into `path-guard` since both were enforcing
substring rules on the same tool inputs. Test suite to 41 cases.

## Pass 3 — quoted/tilde redirects, non-redirect writes (commit `57c1a55`)

**Closes 27 bypass paths** found by adversarial probing.

| Bypass class | Example | Defense |
|---|---|---|
| Quoted redirect target | `> "/etc/passwd"` | Add `"…"` / `'…'` regex variants in `extract_targets` |
| Tilde redirect | `> ~/.bashrc` | Add `~…` regex variant; expand `~` to `$HOME` before zone check |
| Tilde-protected | `> ~/.claude/settings.json` | Pattern matcher gains `~` → `$HOME` expansion |
| Non-redirect modify | `sed -i`, `cp`, `mv`, `dd`, `chmod`, `truncate`, `rm`, `ln -sf`, `install`, `python -c`, `node -e`, `perl -i`, `ruby -i` | New `WRITE_CMDS_RE` backstop: any write operator on the same line as a `[protected]` path mention is blocked, regardless of how the path is formed |

Also extended Read's secret list: `.aws`, `.gnupg`, `.kube`, `.config/gh`,
`.netrc`, `/etc/shadow`, `/proc/*/environ`. Added MultiEdit to the
file-tool dispatch (previously missed — silent bypass). Test suite to
73 cases.

## Pass 4 — config-driven rules (commit `d33d458`)

Replaced the hardcoded protected/secret lists with a gitignore-flavoured
glob matcher reading three concatenated files:

1. `.claude/hooks/path-guard/default.path-guard` — shipped defaults
2. `$HOME/.claude/.path-guard` — user defaults
3. `$CLAUDE_PROJECT_DIR/.path-guard` — project-specific rules

Section headers `[secret]` and `[protected]` split the file. Pattern
syntax: `*`, `**`, `?`, `[abc]`, `~`, leading `/` anchored, no leading
`/` matches basename or path-suffix, trailing `/**` matches the dir
itself. Adversarial probes moved out of `scratch/` into
`test-jailbreak.sh` for permanent CI coverage.

## Pass 5 — second adversarial pass (2026-05-13)

Probed for more jailbreaks; found 35 new ones across eight classes, all
now closed and locked in by `test-jailbreak.sh`.

| # | Bypass class | Example | Defense |
|---|---|---|---|
| A | Newline / line-continuation split | `cp /tmp/evil \<NL>/test/.claude/settings.json` | Normalise newlines to spaces before regex match (`COMMAND_NORM`). The previous per-line `grep` could not see both halves at once. |
| B | Glob substitution in path | `cp /tmp/evil /test/.cla?de/settings.json`, `/test/.[c]laude/settings.json` | Per-char pattern regex now also accepts `?` and `[…]` at each literal position. Bash expands these at exec time but the literal text would otherwise evade the substring match. |
| B' | Brace expansion in path | `cp /tmp/evil /test/.claud{e,e}/settings.json` | Heuristic: `{…}` inside a path-token combined with any write command → block. Cannot be statically resolved positionally. |
| C | Missing write commands | `rsync`, `sponge`, `tar -x`, `unzip`, `git checkout/restore`, `curl -o`, `wget -O`, `gpg --output`, `openssl -out`, `gawk -i inplace` | Added to `WRITE_CMDS_RE`. Commands that have read-only modes (tar, curl, gawk) require the destructive flag as part of the match, so plain reads aren't falsely flagged. |
| D | Tree-walking commands | `find /test/.claude -name X -delete`, `find … -exec rm`, `tar xf -C protected/`, `unzip -d protected/`, `rm -rf protected/` | New `TREE_CMDS_RE` + a directory-prefix regex (`PROTECTED_DIRS_RE`/`SECRET_DIRS_RE`) built from `pattern_dir_prefix`. The file-level regex needs the full path in the command text; tree commands name a directory instead. |
| D' | Pipe-spanning xargs | `find /test/.claude -type f \| xargs rm` | Extra check: pipe between `PROTECTED_DIRS_RE` and `xargs <destructive>` or bare destructive command. The plain backstop's `[^\|&;]*` cannot cross a pipe. |
| E | `sed` long-form `--in-place` | `sed --in-place=.bak s/a/b/ settings.json` | sed/perl regex extended from `-i` short form only to `-i([[:space:]=.]\|$)\|--in-place([[:space:]=]\|$)`. |
| J | Quote / backslash splitting | `cp /tmp/evil /test/.claude\/settings.json`, `/test/".claude"/settings.json`, `/test/.cla""ude/settings.json` | `COMMAND_FLAT` strips `\`, `"`, `'` before backstop greps. Bash strips them at exec time, so they don't affect the resolved path but did obscure the literal substring. |
| N | Wildcard mass-target | `cp /tmp/evil /test/.claude/*`, `rm -rf /test/.claude/*` | Block when a `*` or `?` appears in a path-token alongside a write command and the command also mentions a `[protected]` or `[secret]` directory prefix. |

**Test suite:** 73 probes total (38 prior + 35 new). New probes were
verified to jailbreak the pre-pass hook and hold against the post-pass
hook.

**Regex architecture changes:**
- `glob_to_command_regex` wraps every literal char in
  `(literal|\?|\[[^]]*\])` so glob substitutions are tolerated.
- `pattern_dir_prefix` + `build_dir_prefix_regex` synthesise a regex
  matching the protected directory tree (with a boundary char so
  `.claude` does not match `.claude-backup`).
- `TREE_CMDS_RE` is a subset of `WRITE_CMDS_RE` for commands that name a
  directory rather than a file; these are checked against the dir-prefix
  regex in addition to the per-file regex.
- `COMMAND_NORM` (newlines → spaces) and `COMMAND_FLAT`
  (NORM with `\`/`"`/`'` removed) are pre-computed once per Bash
  invocation and reused across every backstop check.

## Pass 6 — submodule + symlink structure (2026-05-13)

claude-tools is now vendored as a git submodule. `.claude/hooks/<name>/`
became a symlink into `git_modules/claude-tools/hooks/<name>/`, and
`<gitdir>/hooks/pre-push` is a symlink into
`git_modules/claude-tools/scripts/git-hooks/pre-push`. The structural
change opened three new attack surfaces, all unprotected against by the
Pass 5 rule set. 17 new probes added; all now held.

| # | Bypass class | Example | Defense |
|---|---|---|---|
| O | Writes to `.git/` internals | `echo evil > .git/config`, `cp /tmp/evil .git/hooks/post-commit`, `find .git -delete`, `rm -rf .git`, `echo evil > .git/modules/<sub>/hooks/pre-push` | Added `.git` + `.git/**` to default `[protected]`. Matches the directory at the repo root, the file form used by submodules, and the superproject's `.git/modules/<sub>/` tree (since `.git` appears as a path segment). Reads remain allowed (`[protected]`, not `[secret]`) so `git rev-parse` / `git log` style inspection still works. |
| P | Writes to submodule realpath (hook scripts) | `cp /tmp/evil git_modules/claude-tools/hooks/path-guard/hook.sh` | path-guard's symlink resolution rewrites the target to the submodule realpath, which the shipped `.claude/hooks/**/hook.sh` rule no longer matches. Added `claude-tools/hooks/**/hook.sh` and `claude-tools/hooks/**/compact.sh` defaults (matching the realpath when the submodule lives at any path containing the canonical name). `install.sh` also writes `<submodule>/hooks/**/{hook,compact}.sh` to the project-local `.path-guard` so non-canonical installs are still covered. |
| Q | Writes to submodule `scripts/` tree | `cp /tmp/evil git_modules/claude-tools/scripts/git-hooks/pre-push`, same for `scripts/install-hooks.sh` and `scripts/push-github-mirror.sh`; `rm -rf scripts/` | These files are: the source of `<gitdir>/hooks/pre-push` (modifying = arbitrary code on next `git push`), the hook installer (modifying = arbitrary code on next install), and the mirror publisher (modifying = arbitrary code or wrong content reaching the public mirror). Added `claude-tools/scripts/**` to default `[protected]`; `install.sh` also writes `<submodule>/scripts/**` to project-local `.path-guard`. |

The symlink-path form — writing to `.claude/hooks/<name>/hook.sh` itself
rather than the realpath — was already held by Pass 5: the existing
`.claude/hooks/**/hook.sh` pattern feeds the bash backstop's literal-
substring regex, which fires regardless of whether the path is a symlink.
The new realpath/scripts rules are about the resolved targets, which the
substring regex does not see when the command names the resolved path
directly.

**Test suite:** 93 probes total (76 prior + 17 new). New probes were
confirmed to jailbreak the pre-pass hook (baseline run before adding the
rules) and hold after.

**Defense-in-depth rationale:** the default rules use the canonical
directory name `claude-tools` so they hold even if a project never runs
`install.sh`. `install.sh` separately writes the project-relative form
of the same patterns into `<super>/.path-guard` so the protection still
works when the submodule is vendored under a different name (e.g.
`vendor/foo`). Either layer alone is sufficient; together they survive
either being missing.

## Known limitations (deferred)

These are documented inside `hook.sh` and probed-but-marked-allowed in
`test-jailbreak.sh`. They are out of scope because (a) the cost of
fixing is high relative to the realistic threat or (b) a different hook
(`bash-guard`, `read-guard`) is the right place.

1. **`$VAR` / `$(cmd)` in redirect target.** The literal text does not
   contain the resolved path, so neither the zone check nor the
   per-target rule check sees the real target. The backstop sometimes
   still catches it if the path literal happens to appear elsewhere in
   the command (e.g. `$(echo /etc/passwd)` keeps `/etc/passwd` visible),
   but `T=/etc/passwd; … > $T` does not. **Fix would require:** a
   sandboxed brace/parameter expander, or running the command itself in
   a dry-run mode — both invasive and risky.

2. **`cp`/`mv`/`install`/`ln` target argument zone check.** Only
   redirect (`>`, `>>`, `2>`, …) and `tee` targets are extracted into
   `extract_targets` for zone enforcement. A `cp /tmp/x /etc/passwd`
   command whose target is *not* in any `[secret]`/`[protected]` rule
   bypasses zone enforcement, even though the destination is outside
   the allowed roots. **Fix would require:** per-command argument
   parsing (which positional is the target?), and a tolerance for the
   many flag forms (`-t targetdir`, `-T`, etc). **Mitigation:** the
   default `.path-guard` should cover all sensitive paths under
   `[secret]`; if a destination isn't in the rules, it shouldn't be
   protected.

3. **Indirect execution.** `echo … | base64 -d | bash`, `eval "$X"`,
   `source /tmp/foo`, `bash <(curl …)` are all bash-guard's domain.
   path-guard sees only the visible command text.

4. **Relative redirect targets above project root.**
   `> ../../../etc/x` is not captured by `extract_targets` (only
   absolute, `~`, and quoted forms are). The path could escape the
   project root. **Mitigation:** the dir-prefix and backstop regex
   catch this if the resolved path matches any rule (since the literal
   text contains `etc/x`), but a target like `../../../tmp/notarule`
   slips through. Same root cause as #2.

5. **False positives from substring matching.** Because the file-level
   regex is a substring search (`\.claude/+settings\.json` matches
   wherever it appears in the command), a benign command that *names* a
   protected file alongside a write operator on a different path will
   trigger a block. Example: `cp src/foo.txt dst/foo.txt && ls
   .claude/settings.json` — the `cp` and the `ls` are unrelated, but
   the backstop matches `cp … .claude/settings.json` across the `&&`.
   The `[^|&;]*` separator class prevents most of these, but not all.
   **Mitigation:** if you hit this, restructure the command, or move
   the protected mention to a separate line/`bash -c` call.

   **Observed in practice (2026-05-13):** an inline `git commit -m
   "…"` whose message *describes* the hardening (mentioning `rm -r`
   near `.claude/`) is blocked by the new `TREE_CMDS_RE` + dir-prefix
   check. The bash command line contains the message literal, so from
   the hook's view it looks identical to actually running `rm -r` on
   `.claude/`. **Mitigation:** write the message to a scratch file and
   commit with `git commit -F "$CLAUDE_SESSION_SCRATCH/commit-msg.txt"`. The hook does
   not scan file contents, only command text. Future commit messages
   that document hardening passes should expect this and use `-F`.

## How to extend

### Adding a new rule
Edit the appropriate `.path-guard` file. Use the lowest layer that
makes sense:
- shipped in `default.path-guard` if it applies to every project
- in `~/.claude/.path-guard` for per-user rules
- in `$CLAUDE_PROJECT_DIR/.path-guard` for repo-specific rules

After adding, run `bash .claude/hooks/path-guard/test.sh` to confirm
no regressions.

### Adding a new write command
Append to `WRITE_CMDS_RE` in `hook.sh`. If the binary has both
read-only and destructive modes, gate on the destructive flag:

```bash
WRITE_CMDS_RE+='|\bMYCMD\b[^|&;]*[[:space:]]<destructive-flag-regex>'
```

If the command operates on a directory tree rather than a single file
(like `find -delete`, `tar -x`), also append to `TREE_CMDS_RE` so the
directory-prefix check engages.

### Adding a regression probe
Append to `test-jailbreak.sh`. The helper `bash_envelope` (defined in
the file) builds a properly JSON-encoded `{tool_name:"Bash",
tool_input:{command:…}}` envelope. Probes are either `block` or
`allow`; both are checked. Run `bash .claude/hooks/path-guard/test.sh`
to verify.

### When you discover a bypass
1. Add a `probe '<label>' block "$(bash_envelope '<cmd>')"` line at the
   appropriate section in `test-jailbreak.sh`. It should fail (the
   "JAILBREAK" line).
2. Patch `hook.sh` until the probe is held *and* every other probe
   still passes.
3. Add a section in this document under a new "Pass N" heading
   describing the bypass class and the defense.

## Files

- `hook.sh` — the guard itself
- `default.path-guard` — shipped rule defaults
- `test.sh` — unit + integration tests; chains into `test-jailbreak.sh`
- `test-jailbreak.sh` — adversarial probes; each pass appends a new
  section
- `HARDENING.md` — this file
