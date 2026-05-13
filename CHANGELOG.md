# Changelog

All notable changes to claude-tools. Most recent on top.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Changes are grouped by date (no formal releases). When making a new commit,
add an entry under today's date — create the date heading if it does not
exist yet. Group entries under one of:

- **Added** — new features
- **Changed** — changes to existing behaviour
- **Removed** — features dropped
- **Fixed** — bug fixes
- **Security** — security hardening / jailbreak closures

## 2026-05-13

### Security

- **bash-guard pass 2:** Substring-evasion + multi-flag rm hardening. The
  hook now strips backslash/quote chars and collapses line continuations
  before regex matching (`COMMAND_FLAT`), so `r\m -rf /`, `"rm" -rf /`,
  `rm \<NL>-rf /` etc. no longer slip past. The `rm` rule accepts any flag
  layout that gives both recursive AND force semantics (`rm -r -f /`,
  `rm --recursive --force /`, …). 39 adversarial probes added in
  `test-jailbreak.sh`; all hold. Variable / command / printf-hex
  substitution remain deferred-eval known limitations. See
  `hooks/bash-guard/HARDENING.md`.
- **path-guard pass 6:** Submodule + symlink structure jailbreaks.
  Default `[protected]` rules added for `.git/**`, the submodule's
  realpath-resolved hook scripts (`claude-tools/hooks/**/{hook,compact}.sh`),
  and the submodule scripts/ tree (`claude-tools/scripts/**`). 17 new
  probes; all hold. See `hooks/path-guard/HARDENING.md`.

### Added

- **`scripts/push-github-mirror.sh`** — squashes a source revision into a
  single root commit and force-pushes to `origin/github-mirror`, so a
  Forgejo-→-GitHub mirror exposes only the current tree (no internal
  history). Used by the new pre-push hook for automatic mirroring;
  re-runnable manually for ad-hoc snapshots.
- **`scripts/git-hooks/pre-push`** — triggers `push-github-mirror.sh`
  automatically when `main` is pushed to `origin`. Mirror commit is
  pushed before the main push completes, so a single `git push` keeps
  the mirror in sync.
- **`scripts/install-hooks.sh`** — symlinks every entry under
  `scripts/git-hooks/` into the checkout's `<gitdir>/hooks/` directory,
  for both regular clones and submodule checkouts. Existing real hook
  files are backed up before being replaced.

### Changed

- **`README.md`:** prominent disclaimer that most of the code is
  AI-generated and unaudited (hardening passes are real, but the
  underlying code is not security-audited — treat as defence in depth,
  not a trusted boundary). License section now inlines a plain-language
  summary of the Unlicense terms instead of a bare `See LICENSE`.
- **`hooks/read-once/`:** merged `compact.sh` into `hook.sh`. The single
  hook now dispatches on `hook_event_name` — `PreToolUse` runs the
  existing read-once tracking, `PostCompact` and `SessionStart` clear
  the per-session cache. `settings.json` wiring needs to point both
  `PostCompact` and `SessionStart(matcher=compact)` at `hook.sh`.
- **`install.sh`:** when `path-guard` is installed, the project-local
  `.path-guard` now also receives `<submodule>/scripts/**` so the
  protection works even when claude-tools is vendored at a
  non-canonical path.
- **LICENSE:** MIT → Unlicense (public-domain dedication).

### Fixed

- **`push-github-mirror.sh`:** when run from a pre-push hook, the parent
  `git push` exports `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE` pointing
  at the main repo. The script's `git checkout --orphan` inside its
  temp worktree previously inherited those vars and corrupted the main
  worktree's HEAD onto `github-mirror`. The script now unsets those
  vars at entry and creates the temp worktree via `mktemp -d` (outside
  the gitdir).

### Removed

- `hooks/read-once/compact.sh` — logic folded into `hook.sh`. Existing
  installations need to update `settings.json` to drop the `compact.sh`
  references in favour of `hook.sh`.

## Earlier

`Initial: extract hooks from canvas-test` and the subsequent README +
install.sh passes that established the submodule-vendoring layout. See
`git log` for the chronological detail; entries above only start when
the changelog was introduced.
