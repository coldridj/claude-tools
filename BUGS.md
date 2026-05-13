# Known issues — test coverage gaps

Tracker for hook test-coverage gaps identified during the audit on
2026-05-13. Each entry has a status box; mark `[x]` when fixed and link
to the commit in the trailing note. Entries are grouped by hook, then
by severity (highest first).

## always-allow

- [ ] **3 test failures depend on `CLAUDE_PROJECT_DIR` being set externally.**
  The hook loads `$CLAUDE_PROJECT_DIR/.always-allow` and the test cases for
  `scripts/build.sh`, `scripts/build-frontend.sh`, `scripts/inspect.sh …`
  expect those patterns to be loaded. With `CLAUDE_PROJECT_DIR` unset
  (running `bash test.sh` from a fresh shell), the test falls back to
  `$PWD/.always-allow` which is empty, and the three assertions fail.
  The test should set up its own isolated `CLAUDE_PROJECT_DIR` + project
  `.always-allow` instead of relying on the user's env.

## session-scratch

- [ ] **No `test.sh` at all.** The hook has zero coverage. Uncovered:
  - SessionStart `mkdir -p` of the per-session dir
  - SessionStart `export CLAUDE_SESSION_ID` / `CLAUDE_SESSION_SCRATCH` to `$CLAUDE_ENV_FILE`
  - SessionStart 7-day GC sweep at the top level of `$CLAUDE_SCRATCH_ROOT/`
  - SessionEnd `rm -rf` of the per-session dir
  - Empty / missing `session_id` or `hook_event_name` guards
  - `$CLAUDE_SCRATCH_ROOT` env-var override (default `.scratch`)
  - `$CLAUDE_PROJECT_DIR` fallback to `$PWD`

## read-once

- [x] **PostCompact dispatch is silently skipped.** `test.sh` referenced
  `$COMPACT_HOOK="$SCRIPT_DIR/compact.sh"` and wrapped the entire
  PostCompact block in `if [ -f "$COMPACT_HOOK" ]; then …`. After the
  compact.sh → hook.sh merge, the file no longer existed; the `if`
  was always false, so every PostCompact assertion was skipped without
  reporting it. **Fixed:** dispatcher now points at `hook.sh`, guard
  removed.
- [x] **`SessionStart(matcher=compact)` has zero coverage.** **Fixed:**
  new probes exercise the SessionStart-fallback dispatch path.
- [x] **Test 10 (TTL expiry) has stale assertions / upstream layout.**
  **Fixed:** Test 10 removed (it asserted the upstream "Re-read allowed
  after Xm" wording and probed the upstream `session-<hash>.jsonl`
  cache layout). The expired-event-in-stats check was folded into
  Test 11 (custom TTL), which exercises the same path with the
  current `<scratch>/<sid>/read-once/<agent>.jsonl` layout.
- [x] **Group 20 / Group 21 reference an upstream `./read-once` CLI**
  that doesn't exist in this fork at that path. **Fixed:** Groups 20
  and 21 removed; their probes were testing the upstream installer
  rather than the hook itself.
- [x] **Subagent isolation is untested.** **Fixed:** `make_input` gained
  an `agent_id` parameter, new probes exercise main/subagent-A/
  subagent-B caches being independent in the same session.
- [x] **Cost-info string in advisory (Group 19) is flaky.** Resolved by
  fixing the bigger framing issue: `make_input` now emits a
  `hook_event_name: "PreToolUse"` field. Without it the merged hook's
  case statement exited at the `*) exit 0 ;;` branch and produced no
  output at all, which was the root cause of cost-info appearing
  missing in some runs. The Sonnet-cost assertion now passes
  deterministically.

### Newly-introduced test gaps (post-fix)

- [ ] **`$CLAUDE_PROJECT_DIR` is now exported from the top of `test.sh`**
  to keep the per-session cache isolated to `$TEST_DIR`. If any future
  test relies on the un-set behaviour (hook falls back to `$PWD`), it
  will need to clear `CLAUDE_PROJECT_DIR` explicitly.

## path-guard

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
- [ ] **Custom `deny:` rules are not explicitly tested.** The hook
  supports both `allow:` and `deny:` entries; only `allow:` has
  visible coverage via `BASH_GUARD_CONFIG`.
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
- [ ] **Layered-config testing is structurally absent across four
  hooks** (always-allow, path-guard, read-guard, bash-guard). All four
  use the same three-file concatenation pattern; a single shared test
  harness (or a per-hook `<NAME>_USER_CONFIG` / `<NAME>_PROJECT_CONFIG`
  env-var override, matching the existing `<NAME>_HOOK_DIR` knob) would
  close all four gaps at once.
