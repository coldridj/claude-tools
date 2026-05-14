# always-allow — hardening notes

Companion to `hook.sh`. Catalogues known limitations, ambiguous edge cases,
and deferred hardening work. Mirrors the structure of
`hooks/path-guard/HARDENING.md`.

Findings are bucketed by severity, then mode (parser / matcher / IO).

## Severity legend

- **High** — the hook emits the wrong decision (auto-allows something it
  shouldn't, or rejects something it should pass).
- **Medium** — surprises the user but does not weaken the security model
  (silent skips, opaque errors, confusing precedence).
- **Low** — cosmetic, documentation, or relies on rare environments.

---

## Parser / config loader

### Medium — a pattern line that is exactly `[xxx]` is parsed as a section header

The header regex is `^\[([a-z]+)\]$` — anchored on both ends, requiring
the entire trimmed line to be a bracketed lowercase-alpha token. So:

| Line | Parsed as |
|---|---|
| `[allow]` | section header (correct) |
| `[xyz]` | section header (mis-parse: user may have intended an ERE char-class pattern matching a single `x`, `y`, or `z`) |
| `[xyz]foo` | pattern (the `foo` suffix defeats the `]$` anchor) |
| `[Allow]` | pattern (uppercase rejected by `[a-z]+`) |

The high-severity case is the bare `[xyz]` line: the user's intended
pattern is silently lost and the following lines load into a phantom
section `xyz` that's then silently skipped as "unknown". `[xyz]foo` is
parsed correctly as a pattern because the regex demands the bracket
close immediately before end-of-line.

**Mitigation candidates:**

1. Reject section names that don't appear in a known whitelist
   (`allow`, `background`, `bg`) and log a warning to stderr — making
   the loss visible rather than silent.
2. Require an explicit `[allow]` header at the top of every file (drops
   the backward-compat "untagged → [allow]" rule).
3. Document that bare `[xxx]` lines occupy the section-header
   namespace; recommend writing single-char classes as `^[xyz]$` etc.
   which won't collide.

Currently mitigated by: pure documentation in the hook header.

### Medium — section header regex is over-strict

`^\[([a-z]+)\]$` rejects:

- Uppercase / mixed case (`[Allow]`, `[BG]`).
- Hyphens / underscores (`[allow-bg]`, `[no_prompt]`).
- Whitespace inside brackets (`[ allow ]`).
- Numeric chars (`[allow2]`).

These all fall through and are loaded as patterns in the previous
section (typically `allow`) — usually doing nothing useful because the
pattern is `[xxx]` which only matches a literal `x`. The user gets no
feedback that their header was ignored.

**Mitigation candidates:**

1. Relax to `^\[([a-zA-Z0-9_-]+)\]$` and normalize to lowercase before
   the case-dispatch.
2. Emit a warning (regardless of `ALWAYS_ALLOW_LOG`) when a bracketed
   line at the start of its content position fails to match the strict
   header regex.

### Medium — patterns with invalid POSIX ERE crash at match time **(CLOSED 2026-05-15)**

`load_config` accepts any pattern verbatim. If a pattern is malformed
(e.g. unclosed `[`, dangling `+`), the `[[ $op =~ $pat ]]` evaluation
during matching aborts with `bash: regex error` and — because
`set -euo pipefail` is in effect — the whole hook exits non-zero,
without ever emitting a decision JSON.

The Claude Code harness treats hook non-zero exits as "block tool"
(exit 2 specifically) or as protocol-violation (other non-zero). Both
are user-hostile when caused by a typo in the user's `.always-allow`.

**Mitigation in place:** `ere_is_valid()` validator wraps a benign
`[[ "" =~ $pat ]]` match with errexit suspended; returns false when
the test's exit code is 2 (POSIX ERE error). `load_config` calls it
on every pattern and skips invalid entries with a stderr warning so a
typo no longer aborts the hook. Test coverage: 4 cases in `test.sh`
(invalid ERE in each of the three config layers + all-invalid config).

### Medium — `local -n` requires bash ≥ 4.3

The `matches()` helper uses `local -n arr=$arr_name` (namref). This is
fine on Linux distros that ship bash 4.4+ but breaks on macOS where the
system bash is 3.2 (pre-namref). The hook will not load.

**Mitigation:** install.sh already requires bash 4.0+ via the
`#!/bin/bash` shebang resolution; the macOS user is expected to install
bash via Homebrew. Worth documenting in README.

### Low — CRLF in config files is not normalised

If a user edits `.always-allow` on Windows and the file ends up with
`\r\n` line endings, each pattern has a trailing `\r`. The
whitespace-trimming on `entry` removes it (because `\r` is
`[[:space:]]`) — so the current code handles this. Documented for
future safety: do not weaken the trimming step.

---

## Matcher

### Medium — pattern matching does not normalise the command

The hook matches the raw `tool_input.command` string. Variants that are
semantically equivalent miss:

- Leading/trailing whitespace: `  bash scripts/build.sh` → no match for
  `^(bash )?scripts/build\.sh`.
- Quoted form: `'bash scripts/build.sh'` (literal quotes around the
  whole command, as some tools emit) → no match.
- Absolute path: `/repo/scripts/build.sh` → no match.
- `./` prefix: `./scripts/build.sh` → no match.
- `bash -c "scripts/build.sh"` → no match against the inner script
  pattern.

This is intentional: the matcher is a literal-prefix mechanism and the
user is expected to anchor their patterns appropriately. But it's a
source of "why didn't this get auto-allowed?" surprises.

**Mitigation candidates:**

1. Document the literal-match contract prominently in the README.
2. Optionally normalise leading whitespace before matching.
3. Provide a `^(\./)?(bash )?` helper anchor in
   `default.always-allow` for the common script-invocation case.

### Low — `run_in_background` accepts only `true` / `false`

`jq -r '... // false'` returns the JSON value as a string. The
comparison is `[ "$RUN_IN_BG" = "true" ]`. This means:

- `true` (boolean) → matches.
- `"true"` (string, lower-case) → matches.
- `"True"` / `"TRUE"` → does not match, treated as foreground.

Claude Code's tool schema declares the field as boolean, so the only
way to hit the string-`"True"` case is a misbehaving client. Not worth
hardening.

---

## I/O / runtime

### Medium — `jq` failure aborts the hook hard **(CLOSED 2026-05-15)**

If `jq` is missing from `$PATH`, the first `echo "$INPUT" | jq …` call
fails. Under `set -euo pipefail` the hook exits non-zero and the
Claude Code harness treats this as "block". The user has no idea
their permission prompt is being skipped silently.

**Mitigation in place:** early `command -v jq` check at hook entry;
missing jq emits a `[always-allow] jq not found in PATH — fail-open,
no auto-allow this call` warning on stderr and exits 0 (the harness
then falls back to the default permission prompt). Test coverage: 1
case in `test.sh` using `PATH=$(mktemp -d)` with only `cat` symlinked
in.

Note that `install.sh` lists jq as a dependency, so a missing jq is
usually a misinstall.

### Low — `HOOK_DIR` resolution does not follow symlinks

`HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` returns the
symlink's parent, not the realpath. In typical installs the hook is
symlinked from `.claude/hooks/always-allow/hook.sh` → the claude-tools
submodule, so `HOOK_DIR` is `.claude/hooks/always-allow/` — and
`default.always-allow` is read from there (correct: the symlink
includes that file too in the `always-allow/` symlinked directory).

This works because `install.sh` symlinks the **directory** rather than
individual files. If someone symlinks only `hook.sh`, the default
config will fail to load.

**Mitigation:**

1. Document the all-or-nothing symlink contract in the README.
2. Optionally `realpath -m` the `BASH_SOURCE[0]` resolution.

### Low — `$HOME` expansion in user config path is unconditional

`load_config "$HOME/.claude/.always-allow"` will silently fail if
`$HOME` is unset (rare; CI environments sometimes). The hook still
loads the project file and continues. No mitigation needed beyond a
test that exercises an unset `$HOME`.

---

## Test-coverage gaps closed by this hardening pass

See `BUGS.md` in the claude-tools root for the status of each item.

- Integration tests no longer depend on the caller's
  `CLAUDE_PROJECT_DIR` — closed in the test.sh rewrite that landed
  alongside this doc.
- Layered config (default + user + project) now has explicit coverage.
- Section parsing edge cases (uppercase, whitespace, malformed
  brackets) covered.
- `ALWAYS_ALLOW_DISABLED=1`, `ALWAYS_ALLOW_HOOK_DIR=…`, and
  `ALWAYS_ALLOW_LOG=1` all covered.

## Open hardening items

- Stricter / more informative section header parsing.
- Optional command normalisation (leading whitespace, `./` prefix) — deferred to the C# daemon rewrite which will do proper command parsing.
- macOS bash-3.2 fallback (or hard-fail with a clear error).

## Adversarial probe sweep — 2026-05-15

51-probe sweep added in `test-jailbreak.sh`. All hold against the
current hook. Bypass classes covered (each with at least one
"JAILBREAK if auto-allowed" probe):

| # | Class | Defense |
|---|---|---|
| 1 | Filter-segment redirect (`cmd \| tail > /etc/passwd`) | `is_safe_filter` rejects `>` in segment. |
| 2 | Absolute-path filter binary (`cmd \| /bin/tail`) | First-token check rejects `/`. |
| 3 | `$VAR` / `$()` / backtick in filter binary | First-token check rejects `$` and backtick. |
| 4 | Non-whitelist filter (`tee`, `sponge`, `sed -i`, `awk -i inplace`, `cat`) | `tee`/`sponge`/`sed -i`/`awk -i inplace`/`cat` deliberately excluded from `SAFE_PIPE_FILTERS`. |
| 5 | Quoted filter binary (`"tail"`, `t""ail`) | Matcher sees the literal first token; whitelist check fails. |
| 6 | Multi-command in filter segment (`\| tail\n rm -rf /`) | Top-level multi-command guard (newline) fires before pipe analysis. |
| 7 | Multi-command guards (`&&`, `\|\|`, `;`, newline, `\|&`) | Hard reject in `[[ $COMMAND =~ ... ]]` at entry. |
| 8 | Substring evasion of base command (`b\ash`, `"bash"`, `b""ash`, `b''ash`, leading whitespace, tab) | Anchored pattern does not match the literal evasion-shape — the matcher does not strip quotes/backslashes. |
| 9 | Command substitution wrapping base (`$(echo bash …)`, `` `echo bash …` ``, `$EVIL …`, `${EVIL} …`, brace expansion `{scripts,evil}/…`) | Anchored pattern requires a literal prefix; substitution-shapes don't match. |

Plus parser edge cases pinned (each holds): `[allow]` rejects bg
invocations, `[background]` accepts both fg and bg, unknown section
names silently drop their patterns, `[xyz]` mis-parse is pinned,
section context does not leak across config files, Read-tool inputs
always pass through silently.

Known limitations probed as `allow` with `KNOWN LIMITATION` markers:

- `$VAR` / `$(…)` / backtick in argv position smuggles a payload at
  exec time. The matcher does not see through deferred evaluation.
- Unanchored patterns (e.g. `scripts/test\.sh` without `^`) match
  anywhere in the command. By design; user's responsibility.
- Embedded-newline pattern lines are split into two patterns by the
  config line reader (bash ERE has no multi-line literal).
