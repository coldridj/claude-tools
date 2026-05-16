# Claude Code — claude-tools/ instructions

Loaded when working inside the `claude-tools` submodule (a vendored bundle of PreToolUse / PostToolUse / SessionStart / SessionEnd hooks shared across projects).

## Run every hook's tests before committing

Before any commit touching `git_modules/claude-tools/`, run `hooks/test-all.sh` and confirm zero failures. The runner invokes every hook's own `test.sh` in sequence. Hook scripts are the last line of defence against an agent doing something destructive; a regression in one of them has bigger blast radius than the change itself.

If a hook's tests are failing for reasons unrelated to the change, document in `BUGS.md` rather than skipping — and surface the failure to me before proceeding.

## Where things live

- `hooks/<name>/hook.sh` — the hook body (PreToolUse / PostToolUse / etc.).
- `hooks/<name>/test.sh` — unit + integration tests.
- `hooks/<name>/test-jailbreak.sh` — adversarial probes for security-critical hooks (path-guard, bash-guard, always-allow).
- `hooks/<name>/HARDENING.md` — chronological hardening log; append at bottom, don't edit prior entries.
- `hooks/<name>/README.md` — user-facing reference.
- `hooks/lib/` — shared bash helpers.
- `hooks/test-all.sh` — top-level runner; per-suite PASS/FAIL.
- `BUGS.md` — open test-coverage gaps and intentional non-blocks.
- `CHANGELOG.md` — dated entry per commit; closed BUGS.md items move here.
- `scripts/install-hooks.sh` — wires the hooks into a consumer project's `<gitdir>/hooks/` via symlinks.
- `scripts/git-hooks/pre-push` — auto-mirrors commits to the GitHub mirror.

## Daemon rewrite in flight

A C# NativeAOT daemon (spec at `.scratch/scripts/task-14-daemon-requirements-2026-05-15.md`) will consolidate hook execution into a per-project shared process. Current bash hook bodies stay as reference implementation + deliberate fallback (per-hook env-var opt-out). Several BUGS.md items are deferred to that rewrite — see the file.
