#!/usr/bin/env bash
# Adversarial probes for always-allow.
#
# The hook auto-approves Bash commands that match an ERE pattern in any of
# its three config layers (default + user + project). Each probe configures
# a benign allowlist and feeds in a crafted command that *should* be
# rejected (no auto-allow) even though it looks superficially close to an
# allowlisted shape. Any "JAILBREAK" line below is a defect.
#
# Run as part of test.sh, or directly:
#   bash test-jailbreak.sh [path/to/hook.sh]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="${1:-$SCRIPT_DIR/hook.sh}"

JB_COUNT=0
HELD_COUNT=0

# Build a Bash-tool input JSON.
make_input() {
  jq -cn --arg cmd "$1" --argjson bg "${2:-false}" \
    '{"tool_name":"Bash","tool_input":{"command":$cmd,"run_in_background":$bg}}'
}

# Run the hook with an isolated 3-layer fixture; populate HOOK_RC and
# HOOK_STDOUT. Matches the `run_isolated` helper in test.sh.
fixture_run() {
  local project_cfg="$1" command="$2" bg="${3:-false}"
  local user_cfg="${4:-}" default_cfg="${5:-}"
  local proj_dir home_dir hook_dir
  proj_dir=$(mktemp -d); home_dir=$(mktemp -d); hook_dir=$(mktemp -d)
  mkdir -p "$home_dir/.claude"
  printf '%s' "$project_cfg"  > "$proj_dir/.always-allow"
  printf '%s' "$user_cfg"     > "$home_dir/.claude/.always-allow"
  printf '%s' "$default_cfg"  > "$hook_dir/default.always-allow"
  local input rc=0
  input=$(make_input "$command" "$bg")
  HOOK_STDOUT=$(echo "$input" \
    | HOME="$home_dir" \
      CLAUDE_PROJECT_DIR="$proj_dir" \
      ALWAYS_ALLOW_HOOK_DIR="$hook_dir" \
      bash "$HOOK" 2>/dev/null) || rc=$?
  HOOK_RC=$rc
  rm -rf "$proj_dir" "$home_dir" "$hook_dir"
}

ALLOW_JSON='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'

# probe <label> <expect: allow|reject> <project-config> <command> [bg]
probe() {
  local label="$1" expect="$2" cfg="$3" cmd="$4" bg="${5:-false}"
  fixture_run "$cfg" "$cmd" "$bg"
  local allowed=0
  [ "$HOOK_RC" -eq 0 ] && [ "$HOOK_STDOUT" = "$ALLOW_JSON" ] && allowed=1
  if [ "$expect" = "reject" ]; then
    if [ "$allowed" -eq 0 ]; then
      printf '\033[32m HELD     \033[0m %s\n' "$label"; HELD_COUNT=$(( HELD_COUNT + 1 ))
    else
      printf '\033[31m JAILBREAK\033[0m %s  (hook auto-allowed; expected reject)\n' "$label"
      JB_COUNT=$(( JB_COUNT + 1 ))
    fi
  else
    if [ "$allowed" -eq 1 ]; then
      printf '\033[32m OK       \033[0m %s (allowed)\n' "$label"
      HELD_COUNT=$(( HELD_COUNT + 1 ))
    else
      printf '\033[31m UNEXPECT \033[0m %s  (expected allow, rc=%s stdout=%s)\n' \
        "$label" "$HOOK_RC" "$HOOK_STDOUT"
      JB_COUNT=$(( JB_COUNT + 1 ))
    fi
  fi
}

# A baseline allowlist used by most probes. Matches `bash scripts/test.sh`
# style invocations (foreground only, no background).
BASE_ALLOW=$'[allow]\n^(bash )?scripts/test\\.sh($|[[:space:]])'

echo "=== Safe-pipe path: filter-segment escapes ==="
# The hook now allows allowlisted base commands followed by pipes into safe
# filters (head/tail/wc/grep/jq/etc.). Probes here try to smuggle a
# destructive payload through that gate.

# Redirect in a filter segment must reject.
probe 'filter segment contains > redirect' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | tail > /etc/passwd'

probe 'filter segment contains >> redirect' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | tail >> /etc/passwd'

# Absolute path to filter binary must reject.
probe 'absolute-path filter binary /bin/tail' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | /bin/tail'

probe 'absolute-path filter binary /usr/bin/grep' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | /usr/bin/grep foo'

# Variable in filter binary must reject (cannot statically resolve).
probe '$VAR in filter binary' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | $EVIL'

probe '${VAR} in filter binary' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | ${EVIL}'

# Backtick / command-sub in filter binary must reject.
probe '$() in filter binary' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | $(echo tail)'

probe 'backtick in filter binary' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | `echo tail`'

# Filter not in safe-filter whitelist must reject. tee, sponge, sed -i,
# awk -i inplace can all write files.
probe 'tee filter (writes file)' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | tee /tmp/captured'

probe 'sponge filter (writes file)' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | sponge log.txt'

probe 'sed -i filter (writes file)' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | sed -i s/x/y/ file'

probe 'awk -i inplace filter (writes file)' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | awk -i inplace 1 file'

# cat is excluded as a matter of read-guard policy.
probe 'cat filter (excluded by read-guard policy)' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | cat'

# Chained filters: every segment must pass; one bad segment rejects all.
probe 'good filter then tee (must reject)' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | tail | tee /tmp/x'

probe 'good filter then sed -i' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | head | sed -i s/x/y/ f'

# Quoted filter binary: the quote/backslash-stripping that bash does at
# runtime is NOT applied by the matcher, so a quoted filter name shouldn't
# look like the bare name to is_safe_filter — and it doesn't (the first
# token is the literal `"tail"` which is not in the whitelist).
probe 'quoted filter binary "tail"' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | "tail"'

probe 'quote-split filter binary t""ail' reject "$BASE_ALLOW" \
  'bash scripts/test.sh | t""ail'

# Multi-statement payloads in a filter segment via newline.
probe 'filter segment contains newline + payload' reject "$BASE_ALLOW" \
  $'bash scripts/test.sh | tail\nrm -rf /'

echo "=== Multi-command guards ==="

probe 'AND chain bypass' reject "$BASE_ALLOW" \
  'bash scripts/test.sh && rm -rf /'

probe 'OR chain bypass' reject "$BASE_ALLOW" \
  'bash scripts/test.sh || rm -rf /'

probe 'semicolon chain bypass' reject "$BASE_ALLOW" \
  'bash scripts/test.sh; rm -rf /'

probe 'newline chain bypass' reject "$BASE_ALLOW" \
  $'bash scripts/test.sh\nrm -rf /'

probe '|& combined pipe-stderr' reject "$BASE_ALLOW" \
  'bash scripts/test.sh |& tail'

probe 'AND chain in [background] section' reject \
  $'[background]\n^(bash )?scripts/run\\.sh' \
  'bash scripts/run.sh && rm -rf /' true

echo "=== Substring evasion: base command name ==="

probe 'backslash-split base command' reject "$BASE_ALLOW" \
  'b\ash scripts/test.sh'

probe 'quote-wrapped base command' reject "$BASE_ALLOW" \
  '"bash" scripts/test.sh'

probe 'empty-quote split base command' reject "$BASE_ALLOW" \
  'b""ash scripts/test.sh'

probe 'single-quote split base command' reject "$BASE_ALLOW" \
  $'b\'\'ash scripts/test.sh'

probe 'fully quoted command' reject "$BASE_ALLOW" \
  '"bash scripts/test.sh"'

probe 'leading whitespace on anchored pattern' reject "$BASE_ALLOW" \
  '  bash scripts/test.sh'

probe 'tab-indented base command' reject "$BASE_ALLOW" \
  $'\tbash scripts/test.sh'

echo "=== Command substitution / brace expansion in base ==="

# $(echo X) X resolves to X at exec time, but the matcher sees the literal
# `$(echo X)` prefix — which does not match an anchored `^bash ...` pattern.
probe '$() wrapping the whole base command' reject "$BASE_ALLOW" \
  '$(echo bash scripts/test.sh)'

probe '$() inside base command name' reject "$BASE_ALLOW" \
  '$(echo bash) scripts/test.sh'

probe 'backtick wrapping the whole base command' reject "$BASE_ALLOW" \
  '`echo bash scripts/test.sh`'

probe '$VAR as base command name' reject "$BASE_ALLOW" \
  '$EVIL scripts/test.sh'

probe '${VAR} as base command name' reject "$BASE_ALLOW" \
  '${EVIL} scripts/test.sh'

# Brace expansion in the script path. The matcher sees `{scripts,evil}` —
# does not match `^(bash )?scripts/test\.sh`.
probe 'brace expansion in script path' reject "$BASE_ALLOW" \
  'bash {scripts,evil}/test.sh'

# But $VAR / $() in *argv* positions is a known limitation (see
# task-17-simple-expansion.md): the base command matches and the
# substitution smuggles a payload. Probed as 'allow' with a KNOWN
# LIMITATION marker so the regression is visible if behaviour changes.
probe '$() in argv position (KNOWN LIMITATION)' allow "$BASE_ALLOW" \
  'bash scripts/test.sh $(rm -rf /)'

probe 'backtick in argv position (KNOWN LIMITATION)' allow "$BASE_ALLOW" \
  'bash scripts/test.sh `rm -rf /`'

echo "=== Background section guards ==="

# A pattern in [background] should NOT allow when invoked foreground if
# the matcher requires the [allow] section. But the current contract is:
# [background] matches both fg and bg. So this is "allow" expected.
probe '[background] pattern matches fg too' allow \
  $'[background]\n^(bash )?scripts/run\\.sh' \
  'bash scripts/run.sh'

# A pattern in [allow] must NOT allow when invoked in bg.
probe '[allow] pattern does NOT match bg' reject \
  "$BASE_ALLOW" \
  'bash scripts/test.sh' true

# Unknown section's patterns must not allow.
probe 'pattern under [mystery] section ignored' reject \
  $'[mystery]\n^(bash )?scripts/test\\.sh' \
  'bash scripts/test.sh'

echo "=== Anchor & regex escape edge cases in user config ==="

# Pattern without ^ anchor matches anywhere — a pattern like `test` would
# match `rm test.sh.backup`. This is intentional (user controls the regex)
# but worth pinning so a future tightening doesn't silently break it.
probe 'unanchored pattern matches anywhere (intentional)' allow \
  $'[allow]\nscripts/test\\.sh' \
  'malicious-prefix bash scripts/test.sh suffix'

# `$` end-of-string anchor: a pattern `^foo$` must NOT match `foo bar`.
probe 'strict end anchor: $ rejects trailing args' reject \
  $'[allow]\n^foo$' \
  'foo bar'

# Literal `$` (escaped) in a pattern matches the dollar sign in the input.
# Not a common config but pin the behaviour.
probe 'literal dollar in pattern matches dollar in input' allow \
  $'[allow]\n^echo \\$foo$' \
  'echo $foo'

# Pattern containing newline (via $'...\n...') is split into two patterns
# by the line reader. Bash ERE has no multi-line literal: `^foo\nbar$`
# becomes pattern A `^foo` (matches anything starting with foo) AND
# pattern B `bar$` (matches anything ending with bar). The author's
# multi-line intent is lost. This is a config-author gotcha, not a hook
# defect — pin the behaviour so it's documented.
probe 'embedded newline in pattern → two loose patterns (CONFIG GOTCHA)' allow \
  $'[allow]\n^foo\nbar$' \
  'foobar'

# An unknown section name silently drops its patterns.
probe 'pattern under unknown [foo] section is dropped' reject \
  $'[foo]\n^cmd$' \
  'cmd'

# Mis-parse: a bracketed-lowercase-token pattern is read as a section
# header. The "bare ERE char class" intent is lost. Pin the known mis-parse.
probe '[xyz] pattern mis-parsed as section header (HARDENING)' reject \
  $'[allow]\n[xyz]' \
  'x'

echo "=== Section-context bleed across config files ==="

# Section context starts fresh per file. A `[background]` at the end of
# the default file does not affect the user file's untagged patterns
# (which route to implicit [allow]).
probe 'section context does not leak across files (default→user)' reject \
  "" \
  'foo' \
  true \
  $'^foo$' \
  $'[background]\n^bar$'

# Same in reverse: a `[background]` at the end of the user file does not
# affect project file's untagged patterns.
probe 'section context does not leak across files (user→project)' reject \
  $'^baz$' \
  'baz' \
  true \
  $'[background]\n^bar$' \
  ""

echo "=== Non-Bash tool inputs pass through silently ==="

# A Read tool input should never produce an allow decision.
RAW_READ='{"tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}'
HOOK_STDOUT_R=$(echo "$RAW_READ" | bash "$HOOK" 2>/dev/null) || true
if [ -z "$HOOK_STDOUT_R" ]; then
  printf '\033[32m HELD     \033[0m %s\n' "Read tool input does not produce an allow"
  HELD_COUNT=$(( HELD_COUNT + 1 ))
else
  printf '\033[31m JAILBREAK\033[0m %s (got: %s)\n' "Read tool input does not produce an allow" "$HOOK_STDOUT_R"
  JB_COUNT=$(( JB_COUNT + 1 ))
fi

echo
if [ "$JB_COUNT" -gt 0 ]; then
  printf '\033[31m%d probe(s) jailbroke.\033[0m %d held.\n' "$JB_COUNT" "$HELD_COUNT"
  exit 1
fi
printf '\033[32mAll %d probes held.\033[0m\n' "$HELD_COUNT"
