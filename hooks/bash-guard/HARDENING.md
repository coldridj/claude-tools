# bash-guard hardening log

Chronological record of adversarial passes on the `bash-guard` PreToolUse
hook, the bypass classes each pass closed, and the limitations that
remain deferred. New passes append a section at the bottom; do not edit
prior entries (they describe state at the time, not current behaviour).

## Why this exists

`bash-guard` blocks shell commands that would cause irreversible damage
or exfiltrate secrets. It runs synchronously before any Bash tool call
and refuses by exiting non-zero. Because it is the choke point on every
shell command Claude issues, every bypass is a high-severity bug: an
LLM tricked into running `rm -rf /` (under any disguise) must hit the
guard, not the filesystem.

Hardening proceeds adversarially — probes go into `test-jailbreak.sh`
first, then the hook is patched until they all hold. The existing
`test.sh` (590 cases) verifies the original behaviour stays intact at
every step.

## Threat model

- **In scope:** an LLM agent issuing Bash tool calls. Adversarial input
  arrives as the `tool_input.command` string. The attacker controls the
  full command text and can insert any shell metacharacters.
- **Out of scope:** kernel-level escapes, signed-script bypasses,
  attacks via tools other than Bash, and runtime decode where the
  visible command is benign and the destructive payload arrives via
  dynamic resolution we cannot statically see (`$VAR`, `$(…)`,
  `printf '\x..'` constructing commands). The last class is documented
  in "Known limitations".

## Pass 1 — initial ruleset (pre-2026-05)

50+ pattern checks for: `rm -rf`, `chmod -R 777`, `curl|sh`, `sudo`,
`mkfs`, disk utilities, db drops, env dumps, cloud destroy, decode-to-
shell, here-doc to shell, language-shell wrappers, sed/perl/ruby in-
place edit, git force-push, gh repo delete, etc. 590 test cases.

## Pass 2 — substring-evasion + multi-flag rm (2026-05-13)

Adversarial audit found 39 jailbreak probes covering eight bypass
classes; 31 jailbroke against the pass-1 hook. All now held.

| # | Bypass class | Example | Defense |
|---|---|---|---|
| A | Backslash splits the command name | `r\m -rf /` | At hook entry, strip `\`, `"`, and `'` chars to build `COMMAND_FLAT` (bash strips these at exec time, so the resolved command is identical — but the literal text would otherwise evade the substring regex). Most rules now read `$COMMAND` which points at `COMMAND_FLAT`. |
| B | Quote-splitting | `"rm" -rf /`, `r""m -rf /`, `'r''m' -rf /` | Same `COMMAND_FLAT` strip handles all of these. |
| C | Embedded newline as statement separator | `echo a\nsudo apt install` | Normalise newlines to `;` in `COMMAND_NORM` (which `COMMAND_FLAT` is derived from). The segment anchors `(^\|[;&\|]\s*)<cmd>\s` then correctly recognise the boundary. Space replacement (path-guard's choice) would erase the boundary and lose the sudo anchor. |
| D | Backslash-newline line continuation hiding flag splits | `rm \<NL>-rf /` (bash joins these into `rm -rf /`) | Normalisation pre-step: `sed ':a;N;$!ba;s/\\\n/ /g'` collapses `\<NL>` to a space before the NL→`;` translation. The rm rule then sees `rm -rf /` on one logical line. |
| E | `rm` flags split across multiple arguments | `rm -r -f /`, `rm --recursive --force /`, `rm -f -r /` | Replaced the original `rm\s+(-[rRf]+)` regex (which required r+f in one flag) with a two-step match: BOTH `(-[a-zA-Z]*r\|--recursive)` AND `(-[a-zA-Z]*f\|--force)` must appear inside the same `[^\|&;]` command segment after `rm`. Order-agnostic; long-form and short-form mix freely. |
| F | Critical-path trailing char class too narrow | `bash -c "rm -rf /"` slipped because `/` was followed by `"`, not `\s` or end-of-line | Broadened the trailing boundary to `[\s"'\'';\|&]` so `/` followed by any shell punctuation counts as a critical-path mention. |
| G | Wrapped quoted argument to shell | `bash -c "rm -rf /"` etc. (composite of A/B/F above) | Now caught via combined COMMAND_FLAT (strips the quotes) + rm-flag-fix + critical-path broadening. |
| H | Hide behind alternate execution paths | `/bin/rm`, `/usr/bin/rm`, `busybox rm`, `command rm`, `env rm`, `exec rm`, `\rm` | These all leave the literal substring `rm` in the command text. The existing rm regex (which is not word-anchored) caught them already; documented here for completeness. |

After this pass: 590/590 original tests still pass; 38/38 new probes
hold; one over-block (curl with newline before pipe-to-sh, which is a
bash syntax error anyway) accepted as a harmless false positive.

## Known limitations (deferred)

Documented inside `hook.sh` and probed as `allow` (with `KNOWN
LIMITATION` in the label) in `test-jailbreak.sh`. Out of scope because
they require deferred-evaluation resolution that a regex-only hook
cannot perform.

1. **Variable substitution.** `a=rm; $a -rf /` resolves to `rm -rf /`
   at bash exec time. The literal command text contains `$a`, not `rm`,
   so substring regex cannot detect the bypass. Same class as
   path-guard's `$VAR` redirect limitation. **Fix would require:** a
   shell parser that tracks variable assignments and substitutes them
   before regex matching. Significant complexity; deferred.

2. **Command substitution.** `$(echo rm) -rf /` and `` `echo rm` -rf / ``
   resolve to `rm -rf /` at bash exec time. Same class as variable
   substitution. **Fix would require:** running the substitution
   commands (which themselves could be dangerous) or symbolic analysis.

3. **printf hex/octal escape construction.** `x=$(printf "\x72\x6d
   -rf /"); $x` builds the command string at runtime via `printf`'s
   `\x..` escapes. The literal text contains `\x72\x6d`, not `rm`.
   **Fix would require:** decoding the printf format string at hook
   time (some success possible: a targeted rule could detect `printf`
   with hex escapes inside `$(…)` or backticks and block as a class).
   Deferred; potential pass-3 target.

4. **Pure deferred-execution patterns generally.** Any construct where
   the dangerous command name appears only after the shell resolves
   variables, commands, or escape sequences slips past substring regex.
   The hook is "defence in depth, not perfect coverage" — runtime
   sandboxing belongs to a different layer.

## Normalisation pipeline (Pass 2)

The hook builds three forms of the command at entry:

```
COMMAND_ORIG   raw input, preserved for the trailing log line
COMMAND_NORM   line-continuations collapsed to a single space, then
               remaining newlines turned into `;`
COMMAND_FLAT   COMMAND_NORM with `\`, `"`, `'` stripped
```

`$COMMAND` is then aliased to `$COMMAND_FLAT`; the bulk of rules run
against that.

Three rules need to *see* quotes/backslashes (the patterns they detect
literally include those characters) and explicitly use `$COMMAND_NORM`
instead:

- **here-doc with quoted delimiter** — `(bash\|sh\|...)\s+<<-?\s*['"]?…`
- **eval with string literal** — `eval\s+['"]`
- **printf with hex/octal escapes piped to shell** —
  `printf\s+['"].*\\\\(x..\|[0-7]{3})…`

## Files

- `hook.sh` — the guard itself
- `test.sh` — 590 unit + integration tests; chains into `test-jailbreak.sh`
- `test-jailbreak.sh` — adversarial probes; each pass appends a section
- `HARDENING.md` — this file
- `README.md` — user-facing config / install reference
