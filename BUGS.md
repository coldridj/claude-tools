# Known issues — test coverage gaps

Tracker for open hook test-coverage gaps. Each entry has a `[ ]` checkbox;
when fixed, move the entry to `CHANGELOG.md` rather than ticking it here
(this file stays focused on what still needs attention). Entries are
grouped by hook, then by severity (highest first).

## always-allow

- **(deferred to daemon rewrite) Command normalisation missing.**
  `bash scripts/build.sh` works but `  bash scripts/build.sh` (leading
  whitespace), `./scripts/build.sh`, absolute paths, and
  `bash -c "scripts/build.sh"` do not match common patterns. Documented
  in `hooks/always-allow/HARDENING.md` (matcher). Defer to the C# daemon
  rewrite which will do proper command parsing.

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
- **(deferred to daemon rewrite) `COMMAND_NORM` / `COMMAND_FLAT`
  normalisation lacks unit tests in isolation.** Pass-6 added end-to-end
  jailbreak probes for line-continuation collapse and quote-stripping;
  the normalisation functions themselves are not directly tested.
  Extracting them as sourceable helpers is a code change to a hook
  about to be replaced by the C# daemon, so defer the targeted unit
  tests to the rewrite.

## bash-guard

- **(deferred to daemon rewrite) Single-file config model.** bash-guard
  loads exactly one config from `$BASH_GUARD_CONFIG` (or `.bash-guard`
  in CWD), unlike path-guard / read-guard / always-allow which all do
  default + user-wide + project-level layering. Earlier versions of this
  file claimed bash-guard followed the same three-file pattern — that
  was incorrect. Adding 3-layer loading is a code change to `hook.sh`
  and is deferred until the C# daemon rewrite consolidates config
  loading across hooks (see `task-14-daemon-requirements-2026-05-15.md`).
- **(deferred to daemon rewrite) `COMMAND_NORM` / `COMMAND_FLAT`
  normalisation lacks unit tests in isolation.** Pass-2 added jailbreak
  probes; the normalisation functions themselves are not directly
  tested. Same rationale as the path-guard equivalent above — defer to
  the C# daemon rewrite.
- **(intentional non-block) `rm` of `~/.claude/projects/*/memory/*.md`.**
  Agent memory files sit inside path-guard's allowed zone (`~/.claude`)
  and aren't covered by any `[secret]`/`[protected]` pattern; bash-guard's
  critical-path `rm` rule also requires recursive+force flags, so plain
  `rm <memory-file>` falls through unblocked. This is *deliberate*:
  CLAUDE.md memory guidance instructs the agent to "update or remove
  memories that turn out to be wrong or outdated", so deletion is a
  normal operation. Adding `[protected]` for the memory tree would force
  scratch+mv on every memory update; a narrow bash-guard rule for `rm`
  specifically was considered and rejected (2026-05-14 audit). If a
  future incident shows the assumption wrong, the rejected rule from
  the audit is the easy first step.

## session-scratch

- **(deferred to daemon rewrite) Shared session_id wipes another live
  session's scratch.** SessionEnd does `rm -rf $SCRATCH_ROOT/$session_id`
  unconditionally, assuming `(session_id, time)` is unique. It isn't
  under `claude --resume`: two terminals re-attaching to the same
  conversation transcript share a session_id, and closing one wipes the
  scratch dir the other is still using. The hook's per-session-id
  isolation test (sibling-session test) passes — the bug only manifests
  when ids collide via resume.

  Mitigation landed at megarepo TODO: post-mortem JSONL log of every
  SessionStart/SessionEnd at `.session-events-<utc-date>.jsonl` so the
  next incident is diagnosable. Structural fix (session-claim file with
  process tracking, or full daemon ownership of session lifecycle)
  deferred to the C# daemon — see
  `task-14-daemon-requirements-2026-05-15.md`. The daemon can track
  per-process session claims and only clean up when the last process
  for a given session_id exits.

## read-guard

(no open items)

## Cross-cutting

(no open items)
