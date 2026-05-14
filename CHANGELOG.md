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

Bug fixes that close a `BUGS.md` entry move out of `BUGS.md` into the
relevant `Fixed`/`Added` section here, so this file is the authoritative
record of what was resolved.

## 2026-05-14

### Fixed

- **`hooks/always-allow/hook.sh`: emit the correct PreToolUse output schema.**
  The hook was printing `{"decision": "allow"}` which is the legacy form
  accepted only for `UserPromptSubmit` / `PostToolUse` / `Stop` / etc. —
  for `PreToolUse`, Claude Code requires the decision nested inside
  `hookSpecificOutput.permissionDecision`. Under strict schema validation
  the legacy form failed with `Hook JSON output validation failed —
  (root): Invalid input`, blocking the affected Bash invocation. Now
  emits `{"hookSpecificOutput":{"hookEventName":"PreToolUse",
  "permissionDecision":"allow"}}`. Tests updated; full suite still
  87/87.

### Changed

- **`hooks/bash-guard/hook.sh`: block-message boilerplate trio collapses
  after first occurrence per session.** The "Do not retry / hardening
  pass / If the operation is needed" three-line footer is constant and
  re-billed as input on every later turn until compaction. After the
  first block per session, the trio is skipped; the per-rule reason +
  suggestion + override stay (they vary per rule). Marker:
  `$CLAUDE_SESSION_SCRATCH/.bash-guard-seen`. Same env-var gate as
  path-guard's squelch — tests don't set it, so the full message is
  exercised by existing assertions. Two new probes pin the suppressed
  form.
- **`hooks/path-guard/hook.sh`: write-block messages now collapse after
  first occurrence per session.** The full scratch+mv workflow used to be
  printed on every write-block; on long sessions that meant the same
  ~400-char block re-billed as input on every later turn until
  compaction. After the first block, a marker
  (`$CLAUDE_SESSION_SCRATCH/.path-guard-seen`) is touched; subsequent
  blocks emit just the one-line header plus a pointer to the earlier
  full message. Squelch only fires when `CLAUDE_SESSION_SCRATCH` is set,
  so the existing unit tests (which don't export it) still exercise the
  full-message path. Two new probes added covering the suppressed form.
- **`hooks/always-allow/hook.sh`: safe trailing pipes are now auto-allowed.**
  The hook used to refuse any command containing `|`, so every
  allowlisted invocation that ended with `2>&1 | tail -20` had to go
  through the permission prompt. The pipe operator is now split out from
  the multi-command guard: `&&`, `||`, `;`, newline still always block,
  but `|` is allowed when every downstream segment is a "safe pipe
  filter" — first token from a hardcoded whitelist of read-only
  stdin→stdout binaries (`head`, `tail`, `wc`, `tr`, `cut`, `sort`,
  `uniq`, `nl`, `rev`, `fold`, `column`, `jq`, `yq`, `grep`, `egrep`,
  `fgrep`, `rg`) and no `>` / `>>` redirect inside the segment.
  `tee` / `sponge` / `sed -i` / `awk -i inplace` are deliberately
  excluded — zone enforcement on those is path-guard's job. The
  whitelist is overridable for tests via
  `ALWAYS_ALLOW_SAFE_PIPE_FILTERS=<names>`. Thirteen new probes added to
  `hooks/always-allow/test.sh`. `test.sh` now also accepts an optional
  `$1` hook-path arg, matching path-guard's invocation style.

### Fixed

- **`hooks/path-guard/hook.sh`: Bash-backstop substring false positives.**
  `build_path_regex` and `build_dir_prefix_regex` now wrap each pattern's
  command-text regex with `(^|[^A-Za-z0-9._-])…([^A-Za-z0-9._-]|$)` so
  basename rules don't match as substrings of unrelated paths. Previously
  the default `.git` / `.git/**` rules matched the `.git` suffix of
  `origin.git` (and any other bare-repo or `*.git` directory), so a
  command like `rm -rf /tmp/x && git init --bare /tmp/x/origin.git`
  triggered the tree-walking backstop with no real protected dir
  involved. Same root cause for `.claude` matching `.claude-backup` /
  `myclaude/...`. Eight regression probes added to `hooks/path-guard/test.sh`
  cover both directions (allow legitimate look-alikes; still block real
  `.git` / `.claude` paths). The remaining direction-blindness in
  `cp` / `install` / `ln` source-vs-destination is logged in `BUGS.md`.

### Added

- **`scripts/test-push-github-mirror.sh`** — first test suite for the
  github-mirror snapshot script. Each test builds a sandboxed `<tmp>/src`
  + bare `<tmp>/origin.git` and copies the script under test into the
  sandbox so its `REPO_ROOT` resolves there (never the real claude-tools
  repo). Covers the manual branch-label form, the `--sha` form invoked
  from the pre-push hook, and a non-`main` branch; each case asserts both
  the commit message on the mirror branch and that the `latest` tag tracks
  the mirror tip.
- **`hooks/session-scratch/test.sh`** — first test suite for the
  session-scratch hook. 24 tests cover SessionStart `mkdir -p`,
  `touch`-bumped mtime, `$CLAUDE_ENV_FILE` export (with append-not-
  overwrite semantics), the 7-day GC sweep, GC preservation of recent
  entries and the just-created session dir, SessionEnd `rm -rf`,
  silent pass-through on missing `session_id` / `hook_event_name` /
  unknown event, custom `$CLAUDE_SCRATCH_ROOT`, and `$CLAUDE_PROJECT_DIR`
  fallback to `$PWD`. Closes the `[ ] No test.sh at all` BUGS.md entry.

### Changed

- **`scripts/push-github-mirror.sh` commit message** now uses the
  abbreviated SHA and drops the redundant label when the script was
  invoked via the pre-push hook (`SOURCE_LABEL == SOURCE_SHA`). Manual
  runs produce `Snapshot of <branch> @ <short>`; hook-driven runs produce
  `Snapshot @ <short>`.
- **`hooks/bash-guard/hook.sh`:** `block()` now auto-extracts the allow
  key from each rule's suggestion text and prints it on a labelled
  `Override: add 'allow: <key>' to .bash-guard.` line, instead of
  leaving it buried mid-sentence on every rule. The redundant
  `, or add 'allow: <key>' to .bash-guard.` suffix is stripped from
  the suggestion automatically, so the override appears exactly once.
  Per-rule call sites unchanged (~90 sites left untouched). The
  trailing "Do not retry" paragraph was rewritten as three short lines
  for memorability.
- **`hooks/path-guard/hook.sh`:** `block_write` message condensed from
  ~12 lines to ~5. The header now includes the rule reason inline
  (`path-guard: cannot write "<target>" — <reason>`), followed by a
  one-line `To proceed:` workflow, the `mv` command, a parenthetical
  explaining the repo-relative path, and `Do not retry.`. The
  executable-bit advisory is appended on a single line when relevant.
- **`hooks/read-guard/hook.sh`:** `block()` simplified to single-arg.
  The `Suggestion:` line is gone for `cat`/`awk`/`grep`/etc. cases
  where it just restated "use Read tool"; the offset/limit hint is
  inlined into the main message for `head`/`tail` and `sed`.
- **`hooks/always-allow/README.md`:** documents the `[allow]` /
  `[background]` (and `[bg]` alias) section system that the hook has
  shipped since the section split. The "What it never auto-allows"
  section no longer claims all background commands are blocked
  (`[background]` patterns DO match background invocations). The
  CLAUDE.md-suggestion block is updated to direct project commands to
  `[allow]` and trusted long-running launchers to `[background]`.
- **`hooks/{read,path,bash}-guard/README.md`:** CLAUDE.md-suggestion
  blocks updated to match the new message wording above. Read-guard's
  suggestion block also picks up the `xxd`/`bat`/`strings` tools in the
  Read-tool list.
- **`hooks/session-scratch/README.md`:** CLAUDE.md-suggestion block
  reinforced to be explicit that writes go to the per-session subdir
  (`.scratch/<session-id>/<file>`), never directly under the scratch
  root. Includes a wrong/right example and an explicit
  cross-session-persistence exception (named subdirs only).
- **`BUGS.md`:** stripped down to open `[ ]` items only. Resolved
  entries are now logged here in CHANGELOG instead of accumulating
  stale `[x]` checkmarks in BUGS.md.

### Fixed

- **`hooks/session-scratch/hook.sh`:** SessionStart now `touch`es the
  per-session dir after `mkdir -p` so the 7-day GC step does not nuke
  the scratch of a `--resume`d session whose dir is already older
  than 7 days. The previous comment claimed `mkdir -p` bumped mtime,
  which is wrong — `mkdir -p` is a no-op on an existing dir. Caught by
  the new `test.sh`.

## 2026-05-13

### Added

- **README per-hook docs table** linking to each hook's README /
  HARDENING / config-default file from the top-level index, so readers
  do not need to traverse the tree to find the hook-specific reference.
- **`latest` git tag** force-pushed to every github-mirror snapshot by
  `scripts/push-github-mirror.sh`. Gives consumers a stable submodule
  pin: `git submodule add … && git checkout latest`. The README's
  install and update instructions now use this flow. Refresh on the
  consumer side needs `git fetch --tags --force origin` because `latest`
  is a moving tag.
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
- **`hooks/always-allow/test.sh`** — layered-config (default + user +
  project) coverage via a new "Layered configs" section (5 tests + 4
  follow-on context-isolation tests), plus a regression-pin test for
  the silently-permissive `[xyz]` section-header parser documented in
  `hooks/always-allow/HARDENING.md`.
- **`hooks/bash-guard/test.sh`** — explicit `deny:` rule coverage. New
  "Custom deny rules" section exercises `deny: rm`, `deny: unlink`,
  `deny: find.*-delete` via `BASH_GUARD_CONFIG`, and confirms unrelated
  commands still pass (six tests).
- **`hooks/read-once/test.sh`** — `SessionStart(matcher=compact)`
  fallback dispatch coverage and subagent-isolation probes (main /
  subagent-A / subagent-B caches are independent within the same
  session).

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

### Changed

- **`hooks/bash-guard/hook.sh`:** `block()` now appends a meta-warning
  telling the agent not to retry with an equivalent command (`shred` for
  `rm`, `nc` for `curl`, `bash <<<` for `bash -c`, base64-decode-to-shell).
  Lets the project CLAUDE.md drop its `## bash-guard interaction` section
  in favour of just-in-time guidance from the hook itself.
- **`hooks/read-once/hook.sh`:** advisory `REASON` now explicitly tells
  the agent to refer to the earlier read rather than re-fetching, so the
  rule arrives only when the cache hit fires. Lets CLAUDE.md drop the
  `## read-once interaction` section.
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
- **`hooks/always-allow/test.sh`:** test suite no longer depends on the
  caller's `$CLAUDE_PROJECT_DIR`. All 74 tests now go through an
  isolated `run_isolated` helper that sets `HOME`, `CLAUDE_PROJECT_DIR`,
  and `ALWAYS_ALLOW_HOOK_DIR` per case; the top of test.sh exports
  `CLAUDE_PROJECT_DIR=/nonexistent-test-project` as a belt-and-braces
  fallback.
- **`hooks/read-once/test.sh`:** `PostCompact` dispatch was silently
  skipped because the test referenced a `compact.sh` file that no
  longer exists after the compact.sh→hook.sh merge. The dispatcher
  now points at `hook.sh` and the `if [ -f … ]` guard is removed.
- **`hooks/read-once/test.sh`:** Test 10 (TTL expiry) was asserting
  upstream wording (`"Re-read allowed after Xm"`) and probing the
  upstream `session-<hash>.jsonl` cache layout. The check was rewritten
  against the current `<scratch>/<sid>/read-once/<agent>.jsonl` layout
  and folded into Test 11.
- **`hooks/read-once/test.sh`:** Groups 20 and 21 (upstream `./read-once`
  CLI assertions) removed — those tested the upstream installer rather
  than the hook itself.
- **`hooks/read-once/test.sh`:** cost-info string in advisory was
  flaky because `make_input` did not emit a `hook_event_name:
  "PreToolUse"` field; without it the merged hook's case statement
  exited at `*) exit 0 ;;` and produced no output. Adding the field
  made the Sonnet-cost assertion deterministic.

### Removed

- `hooks/read-once/compact.sh` — logic folded into `hook.sh`. Existing
  installations need to update `settings.json` to drop the `compact.sh`
  references in favour of `hook.sh`.

## Earlier

`Initial: extract hooks from canvas-test` and the subsequent README +
install.sh passes that established the submodule-vendoring layout. See
`git log` for the chronological detail; entries above only start when
the changelog was introduced.
