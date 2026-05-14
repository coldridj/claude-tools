# Claude Code — claude-tools/ instructions

Loaded when working inside the `claude-tools` submodule (a vendored bundle of PreToolUse / PostToolUse / SessionStart / SessionEnd hooks shared across projects).

## Run every hook's tests before committing

Before any commit that touches `git_modules/claude-tools/`, run `bash hooks/test-all.sh` and confirm zero failures. The runner invokes every hook's own `test.sh` in sequence, so you don't have to remember each one. The hook scripts are the project's last line of defence against an agent doing something destructive; a regression in one of them has bigger blast radius than the change being committed.

If a hook's tests are failing for reasons unrelated to the change being committed, document the failure in `BUGS.md` rather than skipping the run — and surface the failure to the user before proceeding.

## Where things live

- `hooks/<name>/hook.sh` — the hook body (PreToolUse / PostToolUse / etc.).
- `hooks/<name>/test.sh` — unit + integration tests for that hook.
- `hooks/<name>/test-jailbreak.sh` — adversarial probes for security-critical hooks (path-guard, bash-guard, always-allow).
- `hooks/<name>/HARDENING.md` — chronological hardening log; new passes append at the bottom, do not edit prior entries.
- `hooks/<name>/README.md` — user-facing reference for the hook's config / install / env vars.
- `hooks/lib/` — shared bash helpers (e.g. `layered-config.sh` test fixture).
- `hooks/test-all.sh` — top-level runner; reports per-suite PASS/FAIL.
- `BUGS.md` — open test-coverage gaps and intentional non-blocks.
- `CHANGELOG.md` — append a dated entry for every commit; bug fixes that close a `BUGS.md` item move into `CHANGELOG.md` rather than being ticked in place.
- `scripts/install-hooks.sh` — wires the hooks into a consumer project's `<gitdir>/hooks/` via symlinks.
- `scripts/git-hooks/pre-push` — auto-mirrors commits to the GitHub mirror.

## Hook protection

`path-guard` blocks any write to `**/hook.sh` and `**/compact.sh` paths, including from inside this submodule. Editing a hook's body requires the scratch+mv workflow described in the root CLAUDE.md. Test files (`test.sh`, `test-jailbreak.sh`), READMEs, and HARDENING.md are unprotected.

## Daemon rewrite in flight

A C# NativeAOT daemon (spec at `.scratch/scripts/task-14-daemon-requirements-2026-05-15.md`) will consolidate hook execution into a per-project shared process. The current bash hook bodies stay as the reference implementation and a deliberate fallback (per-hook env-var opt-out). Several BUGS.md items are explicitly deferred to that rewrite — see the file for the current list.
