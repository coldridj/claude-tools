# Known issues — test coverage gaps

Tracker for open hook test-coverage gaps. Each entry has a `[ ]` checkbox;
when fixed, move the entry to `CHANGELOG.md` rather than ticking it here
(this file stays focused on what still needs attention). Entries are
grouped by hook, then by severity (highest first).

## always-allow

- [ ] **`jq` failure aborts the hook hard.** If `jq` is missing from
  `$PATH`, `set -euo pipefail` causes the whole hook to exit non-zero;
  the harness then treats the call as blocked. The hook should pre-check
  `command -v jq` and fail-open with a warning. See
  `hooks/always-allow/HARDENING.md` (I/O / runtime).
- [ ] **Invalid POSIX ERE in a `.always-allow` pattern aborts match.**
  Same `set -euo pipefail` interaction — a malformed pattern causes
  `[[ $op =~ $pat ]]` to error and the hook exits non-zero without
  emitting a decision. Pre-validate patterns at load time. See
  `hooks/always-allow/HARDENING.md` (parser).
- [ ] **Command normalisation missing.** `bash scripts/build.sh` works
  but `  bash scripts/build.sh` (leading whitespace), `./scripts/build.sh`,
  absolute paths, and `bash -c "scripts/build.sh"` do not match common
  patterns. Documented in `hooks/always-allow/HARDENING.md` (matcher).

## read-once

- [ ] **`$CLAUDE_PROJECT_DIR` is now exported from the top of `test.sh`**
  to keep the per-session cache isolated to `$TEST_DIR`. If any future
  test relies on the un-set behaviour (hook falls back to `$PWD`), it
  will need to clear `CLAUDE_PROJECT_DIR` explicitly.

## path-guard

- [ ] **`cp` / `install` / `ln` source-vs-destination direction-blindness.**
  The Bash backstop (`WRITE_CMDS_RE[^|&;]*PROTECTED_RE`) treats any
  protected-path mention near a write command as a write *to* it, but
  `cp src dst`, `install src dst`, and `ln src dst` only write to `dst`
  — `src` is read. A command of the form
  `cp <protected-path> /tmp/scratch.sh` is therefore blocked even though
  it is a read of `<protected-path>`, not a write. Repro:
  `cp git_modules/claude-tools/scripts/push-github-mirror.sh /tmp/x`.
  Targeted fix is non-trivial: would need to peel `cp`/`install`/`ln`
  out of `WRITE_CMDS_RE` and parse their args to identify the final
  positional (the destination). Workarounds for now: rename the
  destination to a non-protected basename, or use `Read` + `Write`.
- [ ] **Layered config files are not exercised.** Tests load only
  `default.path-guard`. The user-wide `~/.claude/.path-guard` and the
  project-local `$CLAUDE_PROJECT_DIR/.path-guard` are documented as
  concatenated overlays but have no integration test that exercises
  the load order / merge.
- [ ] **`COMMAND_NORM` / `COMMAND_FLAT` normalisation lacks unit
  tests.** Pass-6 added end-to-end jailbreak probes for line-
  continuation collapse and quote-stripping but no targeted unit tests
  on the normalisation functions in isolation.
- [ ] **Symlink resolution is not exercised end-to-end.** The "tilde
  redirect to hook script (resolved)" probe tests the literal path
  text only — no test creates an actual symlink and verifies
  `realpath -m` resolves through it before the rule check.

## bash-guard

- [ ] **Layered config files are not exercised.** Same default-only
  pattern as path-guard. `$HOME/.claude/.bash-guard` and
  `$CLAUDE_PROJECT_DIR/.bash-guard` load order / merge are not tested.
- [ ] **`COMMAND_NORM` / `COMMAND_FLAT` normalisation lacks unit
  tests.** Pass-2 added jailbreak probes; the normalisation functions
  themselves are not directly tested.

## read-guard

- [ ] **Layered config files are not exercised.** Tests temporarily
  overwrite `$SCRIPT_DIR/default.read-guard` (the shipped file) to
  inject exclusions; the user-wide `~/.claude/.read-guard` and project
  `$CLAUDE_PROJECT_DIR/.read-guard` layering is not tested.
- [ ] **`$CLAUDE_SCRATCH_ROOT/` auto-exemption is not tested
  explicitly.** The hook auto-exempts whatever `$CLAUDE_SCRATCH_ROOT`
  resolves to (default `.scratch/`); no test sets the env var to a
  non-default value and asserts the auto-exemption follows.

## Cross-cutting

- [ ] **No top-level test runner.** Each hook's `test.sh` is invoked
  independently. There is no `hooks/test-all.sh` (or equivalent) that
  runs every hook's suite in sequence and reports a combined result.
  Hard to verify the whole suite before a `git push`.
- [ ] **Layered-config testing is structurally absent across three
  hooks** (path-guard, read-guard, bash-guard). All three use the same
  three-file concatenation pattern; a single shared test harness (or a
  per-hook `<NAME>_USER_CONFIG` / `<NAME>_PROJECT_CONFIG` env-var
  override, matching the existing `<NAME>_HOOK_DIR` knob) would close
  all three gaps at once. always-allow now has layered-config coverage
  via the `run_isolated` helper — that's the model to copy.
