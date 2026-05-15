#!/usr/bin/env bash
# Tests for path-guard hook
#
# Runs all unit tests then chains into test-jailbreak.sh for adversarial probes.

set -euo pipefail
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="${1:-$HOOK_DIR/hook.sh}"

export CLAUDE_PROJECT_DIR="/test/project"
# Ensure the hook finds default.path-guard even when invoked from elsewhere.
export PATH_GUARD_HOOK_DIR="$HOOK_DIR"

# shellcheck disable=SC1091
. "$HOOK_DIR/../lib/layered-config.sh"

ok()   { printf '\033[32m PASS \033[0m %s\n' "$1"; }
fail() { printf '\033[31m FAIL \033[0m %s\n' "$1"; FAILURES=$(( FAILURES + 1 )); }

FAILURES=0

# Run hook expecting it to allow (exit 0)
expect_allow() {
  local label="$1" input="$2"
  local code=0
  printf '%s' "$input" | bash "$HOOK" || code=$?
  if [ "$code" -eq 0 ]; then ok "$label"
  else fail "$label — expected ALLOW, got exit $code"; fi
}

# Run hook expecting it to block (exit 2)
expect_block() {
  local label="$1" input="$2"
  local code=0
  printf '%s' "$input" | bash "$HOOK" 2>/dev/null || code=$?
  if [ "$code" -eq 2 ]; then ok "$label"
  else fail "$label — expected BLOCK (exit 2), got exit $code"; fi
}

echo "=== Edit — zone check ==="

expect_allow "inside project (absolute)" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/test/project/src/app.cs","old_string":"a","new_string":"b"}}'

expect_allow "inside project (relative)" \
  '{"tool_name":"Edit","tool_input":{"file_path":"src/app.cs","old_string":"a","new_string":"b"}}'

expect_allow "inside ~/.claude (non-protected file)" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$HOME"'/.claude/keybindings.json","old_string":"a","new_string":"b"}}'

expect_block "/etc/passwd" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/etc/passwd","old_string":"a","new_string":"b"}}'

expect_block "/tmp file" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/evil.sh","old_string":"a","new_string":"b"}}'

expect_block "path traversal out of project" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/test/project/../../../etc/passwd","old_string":"a","new_string":"b"}}'

echo "=== Edit — protected config files ==="

expect_block "project settings.json" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/test/project/.claude/settings.json","old_string":"a","new_string":"b"}}'

expect_block "project settings.local.json" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/test/project/.claude/settings.local.json","old_string":"a","new_string":"b"}}'

expect_block "project CLAUDE.md" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/test/project/CLAUDE.md","old_string":"a","new_string":"b"}}'

expect_block "hook script (hook.sh)" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/test/project/.claude/hooks/bash-guard/hook.sh","old_string":"a","new_string":"b"}}'

expect_block "hook script (compact.sh)" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/test/project/.claude/hooks/read-once/compact.sh","old_string":"a","new_string":"b"}}'

expect_allow "hook test file (not protected)" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/test/project/.claude/hooks/bash-guard/test.sh","old_string":"a","new_string":"b"}}'

expect_allow "hook README (not protected)" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/test/project/.claude/hooks/README.md","old_string":"a","new_string":"b"}}'

expect_block "global settings.json" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$HOME"'/.claude/settings.json","old_string":"a","new_string":"b"}}'

expect_block "global settings.local.json" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$HOME"'/.claude/settings.local.json","old_string":"a","new_string":"b"}}'

expect_block "global CLAUDE.md" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$HOME"'/.claude/CLAUDE.md","old_string":"a","new_string":"b"}}'

echo "=== Write ==="

expect_allow "inside project" \
  '{"tool_name":"Write","tool_input":{"file_path":"/test/project/out.txt","content":"hello"}}'

expect_allow "new file in project subdir" \
  '{"tool_name":"Write","tool_input":{"file_path":"/test/project/scratch/debug.json","content":"{}"}}'

expect_block "/tmp write" \
  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/evil.sh","content":"rm -rf /"}}'

expect_block "/home/other user" \
  '{"tool_name":"Write","tool_input":{"file_path":"/home/otheruser/.bashrc","content":"evil"}}'

expect_block "Write to hook.sh" \
  '{"tool_name":"Write","tool_input":{"file_path":"/test/project/.claude/hooks/path-guard/hook.sh","content":"exit 0"}}'

echo "=== NotebookEdit ==="

expect_allow "notebook inside project" \
  '{"tool_name":"NotebookEdit","tool_input":{"file_path":"/test/project/notebook.ipynb","cell_id":"1","new_source":"x=1"}}'

expect_block "notebook outside project" \
  '{"tool_name":"NotebookEdit","tool_input":{"file_path":"/tmp/notebook.ipynb","cell_id":"1","new_source":"x=1"}}'

echo "=== Bash redirects — zone check ==="

expect_allow "redirect inside project" \
  '{"tool_name":"Bash","tool_input":{"command":"echo hello > /test/project/out.txt"}}'

expect_allow "redirect to /dev/null" \
  '{"tool_name":"Bash","tool_input":{"command":"cmd > /dev/null 2>&1"}}'

expect_allow "redirect stderr to /dev/stderr" \
  '{"tool_name":"Bash","tool_input":{"command":"cmd 2>/dev/stderr"}}'

expect_block "redirect to /tmp" \
  '{"tool_name":"Bash","tool_input":{"command":"echo evil > /tmp/out.txt"}}'

expect_block "append redirect outside" \
  '{"tool_name":"Bash","tool_input":{"command":"echo log >> /var/log/evil.log"}}'

expect_block "fd redirect outside" \
  '{"tool_name":"Bash","tool_input":{"command":"cmd 2>/etc/bad.log"}}'

echo "=== Bash redirects — protected config files ==="

expect_block "absolute redirect to settings.json" \
  '{"tool_name":"Bash","tool_input":{"command":"echo {} > /test/project/.claude/settings.json"}}'

expect_block "relative redirect to settings.json" \
  '{"tool_name":"Bash","tool_input":{"command":"echo {} > .claude/settings.json"}}'

expect_block "relative redirect to settings.local.json" \
  '{"tool_name":"Bash","tool_input":{"command":"echo {} > .claude/settings.local.json"}}'

expect_block "relative redirect to CLAUDE.md" \
  '{"tool_name":"Bash","tool_input":{"command":"echo # > CLAUDE.md"}}'

echo "=== Bash tee ==="

expect_allow "tee inside project" \
  '{"tool_name":"Bash","tool_input":{"command":"cmd | tee /test/project/out.txt"}}'

expect_allow "tee -a inside project" \
  '{"tool_name":"Bash","tool_input":{"command":"cmd | tee -a /test/project/out.txt"}}'

expect_block "tee to /tmp" \
  '{"tool_name":"Bash","tool_input":{"command":"cmd | tee /tmp/evil.txt"}}'

expect_block "tee to settings.json (absolute)" \
  '{"tool_name":"Bash","tool_input":{"command":"cmd | tee /test/project/.claude/settings.json"}}'

expect_block "tee to settings.json (relative)" \
  '{"tool_name":"Bash","tool_input":{"command":"cmd | tee .claude/settings.json"}}'

echo "=== Read — sensitive directory blocking ==="

expect_block "Read ~/.ssh/id_rsa" \
  '{"tool_name":"Read","tool_input":{"file_path":"'"$HOME"'/.ssh/id_rsa"}}'

expect_block "Read ~/.ssh/config" \
  '{"tool_name":"Read","tool_input":{"file_path":"'"$HOME"'/.ssh/config"}}'

expect_block "Read ~/.ssh dir itself" \
  '{"tool_name":"Read","tool_input":{"file_path":"'"$HOME"'/.ssh"}}'

expect_block "Read ~/.aws/credentials" \
  '{"tool_name":"Read","tool_input":{"file_path":"'"$HOME"'/.aws/credentials"}}'

expect_block "Read ~/.gnupg/secring.gpg" \
  '{"tool_name":"Read","tool_input":{"file_path":"'"$HOME"'/.gnupg/secring.gpg"}}'

expect_block "Read ~/.kube/config" \
  '{"tool_name":"Read","tool_input":{"file_path":"'"$HOME"'/.kube/config"}}'

expect_block "Read ~/.config/gh/hosts.yml" \
  '{"tool_name":"Read","tool_input":{"file_path":"'"$HOME"'/.config/gh/hosts.yml"}}'

expect_block "Read ~/.netrc" \
  '{"tool_name":"Read","tool_input":{"file_path":"'"$HOME"'/.netrc"}}'

expect_block "Read /etc/shadow" \
  '{"tool_name":"Read","tool_input":{"file_path":"/etc/shadow"}}'

expect_block "Read /etc/sudoers" \
  '{"tool_name":"Read","tool_input":{"file_path":"/etc/sudoers"}}'

expect_block "Read /proc/self/environ" \
  '{"tool_name":"Read","tool_input":{"file_path":"/proc/self/environ"}}'

expect_allow "Read inside project" \
  '{"tool_name":"Read","tool_input":{"file_path":"/test/project/README.md"}}'

expect_allow "Read ~/.claude non-protected file" \
  '{"tool_name":"Read","tool_input":{"file_path":"'"$HOME"'/.claude/keybindings.json"}}'

echo "=== MultiEdit — same checks as Edit ==="

expect_allow "MultiEdit inside project" \
  '{"tool_name":"MultiEdit","tool_input":{"file_path":"/test/project/src/x.cs","edits":[{"old_string":"a","new_string":"b"}]}}'

expect_block "MultiEdit /etc/passwd" \
  '{"tool_name":"MultiEdit","tool_input":{"file_path":"/etc/passwd","edits":[{"old_string":"a","new_string":"b"}]}}'

expect_block "MultiEdit settings.json" \
  '{"tool_name":"MultiEdit","tool_input":{"file_path":"/test/project/.claude/settings.json","edits":[{"old_string":"a","new_string":"b"}]}}'

echo "=== Bash — quoted/tilde redirect target zone check ==="

expect_block 'redirect to "/etc/passwd" (double-quoted)' \
  '{"tool_name":"Bash","tool_input":{"command":"echo evil > \"/etc/passwd\""}}'

expect_block "redirect to '/etc/passwd' (single-quoted)" \
  '{"tool_name":"Bash","tool_input":{"command":"echo evil > '\''/etc/passwd'\''"}}'

expect_block "redirect to ~/.bashrc (tilde, outside ~/.claude)" \
  '{"tool_name":"Bash","tool_input":{"command":"echo evil > ~/.bashrc"}}'

expect_block "redirect to ~/.claude/settings.json (tilde + protected)" \
  '{"tool_name":"Bash","tool_input":{"command":"echo {} > ~/.claude/settings.json"}}'

expect_allow "redirect to ~/.claude/keybindings.json (tilde, allowed)" \
  '{"tool_name":"Bash","tool_input":{"command":"echo {} > ~/.claude/keybindings.json"}}'

echo "=== Bash — protected-file backstop (any write op + protected substring) ==="

expect_block "double-slash defeats relative pattern" \
  '{"tool_name":"Bash","tool_input":{"command":"echo {} > .claude//settings.json"}}'

expect_block "sed -i on settings.json" \
  '{"tool_name":"Bash","tool_input":{"command":"sed -i s/foo/bar/ /test/project/.claude/settings.json"}}'

expect_block "perl -i on settings.json" \
  '{"tool_name":"Bash","tool_input":{"command":"perl -i -pe s/a/b/ /test/project/.claude/settings.json"}}'

expect_block "cp into settings.json" \
  '{"tool_name":"Bash","tool_input":{"command":"cp /tmp/evil.json /test/project/.claude/settings.json"}}'

expect_block "mv onto settings.json" \
  '{"tool_name":"Bash","tool_input":{"command":"mv /tmp/evil.json /test/project/.claude/settings.json"}}'

expect_block "install onto hook.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"install -m 755 /tmp/evil.sh /test/project/.claude/hooks/path-guard/hook.sh"}}'

expect_block "dd of=settings.json" \
  '{"tool_name":"Bash","tool_input":{"command":"dd if=/tmp/evil of=/test/project/.claude/settings.json"}}'

expect_block "ln -sf overwriting hook.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"ln -sf /tmp/evil /test/project/.claude/hooks/path-guard/hook.sh"}}'

expect_block "chmod settings.json" \
  '{"tool_name":"Bash","tool_input":{"command":"chmod 777 /test/project/.claude/settings.json"}}'

expect_block "truncate -s 0 hook.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"truncate -s 0 /test/project/.claude/hooks/path-guard/hook.sh"}}'

expect_block "rm -f hook.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -f /test/project/.claude/hooks/path-guard/hook.sh"}}'

expect_block "python writes settings.json" \
  '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"open('\''/test/project/.claude/settings.json'\'','\''w'\'').write('\''x'\'')\""}}'

expect_block "node writes settings.json" \
  '{"tool_name":"Bash","tool_input":{"command":"node -e \"require('\''fs'\'').writeFileSync('\''/test/project/.claude/settings.json'\'','\''x'\'')\""}}'

expect_allow "ls .claude/settings.json (read-only mention)" \
  '{"tool_name":"Bash","tool_input":{"command":"ls -la /test/project/.claude/settings.json"}}'

echo "=== Config-driven [secret] rules — cert/key/secret extensions ==="

expect_block "Read tls.pem"               '{"tool_name":"Read","tool_input":{"file_path":"/test/project/tls.pem"}}'
expect_block "Read server.key"            '{"tool_name":"Read","tool_input":{"file_path":"/test/project/server.key"}}'
expect_block "Read foo.p12"               '{"tool_name":"Read","tool_input":{"file_path":"/test/project/foo.p12"}}'
expect_block "Read bar.pfx"               '{"tool_name":"Read","tool_input":{"file_path":"/test/project/bar.pfx"}}'
expect_block "Read site.crt"              '{"tool_name":"Read","tool_input":{"file_path":"/test/project/site.crt"}}'
expect_block "Read keys.kdbx"             '{"tool_name":"Read","tool_input":{"file_path":"/test/project/keys.kdbx"}}'
expect_block "Read foo_rsa"               '{"tool_name":"Read","tool_input":{"file_path":"/test/project/keys/foo_rsa"}}'
expect_block "Read id_ed25519"            '{"tool_name":"Read","tool_input":{"file_path":"/test/project/id_ed25519"}}'

echo "=== Config-driven [secret] rules — env / secret config files ==="

expect_block "Read .env"                  '{"tool_name":"Read","tool_input":{"file_path":"/test/project/.env"}}'
expect_block "Read .env.production"       '{"tool_name":"Read","tool_input":{"file_path":"/test/project/.env.production"}}'
expect_block "Read secrets.yaml"          '{"tool_name":"Read","tool_input":{"file_path":"/test/project/secrets.yaml"}}'
expect_block "Read credentials.json"      '{"tool_name":"Read","tool_input":{"file_path":"/test/project/config/credentials.json"}}'
expect_block "Read service-account-foo.json" '{"tool_name":"Read","tool_input":{"file_path":"/test/project/service-account-foo.json"}}'

echo "=== Config-driven [secret] rules — writes also blocked ==="

expect_block "Write project tls.pem"      '{"tool_name":"Write","tool_input":{"file_path":"/test/project/tls.pem","content":"x"}}'
expect_block "redirect to .env"           '{"tool_name":"Bash","tool_input":{"command":"echo SECRET=1 > /test/project/.env"}}'
expect_block "cp into tls.pem"            '{"tool_name":"Bash","tool_input":{"command":"cp /tmp/x /test/project/tls.pem"}}'
expect_block "tee into secrets.yaml"      '{"tool_name":"Bash","tool_input":{"command":"echo x | tee /test/project/secrets.yaml"}}'

echo "=== [protected] rules — writes blocked but reads still allowed ==="

expect_allow "Read .claude/settings.json" '{"tool_name":"Read","tool_input":{"file_path":"/test/project/.claude/settings.json"}}'
expect_allow "Read CLAUDE.md"             '{"tool_name":"Read","tool_input":{"file_path":"/test/project/CLAUDE.md"}}'
expect_allow "Read hook.sh"               '{"tool_name":"Read","tool_input":{"file_path":"/test/project/.claude/hooks/path-guard/hook.sh"}}'

echo "=== Bash backstop word-boundary regressions ==="
# The default rules `.git` and `.git/**` once matched as substrings, so any
# command containing `*.git` (typical bare-repo naming) plus a write op was
# falsely blocked. Same for `.claude` matching inside `.claude-backup`,
# `myclaude/...`, etc. The boundary wrap in build_path_regex /
# build_dir_prefix_regex requires the pattern to be flanked by non-word chars.

# Use in-zone paths so the new Bash command-arg zone check (which blocks
# writes to /tmp, /var, /opt, etc.) doesn't interfere with the
# word-boundary intent here. The point is the boundary regex, not zones.

expect_allow "rm + bare-repo init (origin.git is not .git)" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf /test/project/var/sb && mkdir -p /test/project/var/sb && git init --bare /test/project/var/sb/origin.git"}}'

expect_allow "cp into foo.git" \
  '{"tool_name":"Bash","tool_input":{"command":"cp /test/project/var/src.json /test/project/var/foo.git"}}'

expect_allow "rm -rf path/origin.git" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf /test/project/var/sandbox/origin.git"}}'

expect_allow ".claude-backup is not .claude" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf /test/project/var/.claude-backup/file"}}'

expect_allow "myclaude/ prefix is not .claude" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf /test/project/var/myclaude/file"}}'

# And the legitimate matches must still block.
expect_block "rm -rf /test/project/.git (legit)" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf /test/project/.git"}}'

expect_block "rm -rf .git/objects (legit, dir-prefix tree match)" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf /test/project/sub/.git/objects"}}'

expect_block "find -delete inside .claude (legit, tree)" \
  '{"tool_name":"Bash","tool_input":{"command":"find /test/project/.claude -name '\''*.json'\'' -delete"}}'

echo "=== Bash backstop statement-start anchoring (task #19 regressions) ==="
# Command names in WRITE_CMDS_RE (cp, mv, install, ln, rm, chmod, …) once
# matched as substrings inside filenames like `install-hooks.sh` —
# `bash git_modules/claude-tools/scripts/install-hooks.sh` was falsely
# blocked because the `install` substring of `install-hooks.sh` lit up
# `\binstall\b`, combined with the `claude-tools/scripts/**` protected
# pattern on the same line. The STMT_START anchor requires the command
# to appear after a statement boundary (^, ;, |, &, (, {, backtick).

expect_allow "bash invoking install-hooks.sh under protected dir" \
  '{"tool_name":"Bash","tool_input":{"command":"bash git_modules/claude-tools/scripts/install-hooks.sh"}}'

expect_allow "bash invoking a script with cp in its name under protected dir" \
  '{"tool_name":"Bash","tool_input":{"command":"bash git_modules/claude-tools/scripts/cp-frontend.sh"}}'

expect_allow "bash invoking a script with mv in its name under protected dir" \
  '{"tool_name":"Bash","tool_input":{"command":"bash git_modules/claude-tools/scripts/mv-data.sh"}}'

expect_allow "bash invoking a script with rm in its name under protected dir" \
  '{"tool_name":"Bash","tool_input":{"command":"bash git_modules/claude-tools/scripts/rm-cache.sh"}}'

expect_allow "echo with substring 'rm' in arg" \
  '{"tool_name":"Bash","tool_input":{"command":"echo \"got-rm-result\" > /test/project/out.txt"}}'

expect_allow "pipe terminating in echo with substring 'mv' in arg" \
  '{"tool_name":"Bash","tool_input":{"command":"find /tmp/foo | head -3 | echo with-mv-inside-arg"}}'

# Real positives — these MUST still block.

expect_block "install at start of line targeting protected dir" \
  '{"tool_name":"Bash","tool_input":{"command":"install -m 755 /tmp/src /test/project/git_modules/claude-tools/scripts/x.sh"}}'

expect_block "install after semicolon targeting protected dir" \
  '{"tool_name":"Bash","tool_input":{"command":"echo hi; install /tmp/src /test/project/git_modules/claude-tools/scripts/x.sh"}}'

expect_block "rm after && targeting protected" \
  '{"tool_name":"Bash","tool_input":{"command":"true && rm /test/project/git_modules/claude-tools/scripts/x.sh"}}'

expect_block "rm inside subshell targeting protected" \
  '{"tool_name":"Bash","tool_input":{"command":"(rm /test/project/git_modules/claude-tools/scripts/x.sh)"}}'

expect_block "rm inside brace group targeting protected" \
  '{"tool_name":"Bash","tool_input":{"command":"{ rm /test/project/git_modules/claude-tools/scripts/x.sh; }"}}'

echo "=== Bash command-arg zone check (write-intent + path outside zone) ==="
# Previously: path-guard only zone-checked redirect/tee targets, so
# `mkdir ~/.local/bin` and `corepack enable --install-directory ~/.local/bin`
# slipped through despite writing outside $CLAUDE_PROJECT_DIR and ~/.claude.
# The new WRITE_INTENT_RE gate + extract_command_paths scan closes the gap.
# Reported repro: mkdir -p ~/.local/bin && corepack enable --install-directory
# ~/.local/bin 2>&1 && ~/.local/bin/pnpm --version

expect_block "mkdir at top level writing to ~/.local/bin (reported repro)" \
  '{"tool_name":"Bash","tool_input":{"command":"mkdir -p ~/.local/bin"}}'

expect_block "mkdir writing to /opt/foo (outside zones)" \
  '{"tool_name":"Bash","tool_input":{"command":"mkdir /opt/foo"}}'

expect_block "corepack --install-directory targeting ~/.local/bin (reported repro)" \
  '{"tool_name":"Bash","tool_input":{"command":"corepack enable --install-directory ~/.local/bin"}}'

expect_block "&& chain: mkdir + corepack into ~/.local/bin (full reported repro)" \
  '{"tool_name":"Bash","tool_input":{"command":"mkdir -p ~/.local/bin && corepack enable --install-directory ~/.local/bin 2>&1 && ~/.local/bin/pnpm --version"}}'

expect_block "install -m 755 src targeting /usr/local/bin" \
  '{"tool_name":"Bash","tool_input":{"command":"install -m 755 /tmp/src /usr/local/bin/foo"}}'

expect_block "rsync into ~/dest (outside zone)" \
  '{"tool_name":"Bash","tool_input":{"command":"rsync -av /test/project/src ~/dest"}}'

expect_block "--prefix=/opt/local on a make-style command" \
  '{"tool_name":"Bash","tool_input":{"command":"cargo install --prefix /opt/local --root /opt/local foo"}}'

# Inside-zone targets must still pass.

expect_allow "mkdir under project (in zone)" \
  '{"tool_name":"Bash","tool_input":{"command":"mkdir -p /test/project/.scratch/subdir"}}'

expect_allow "mkdir under ~/.claude (in zone)" \
  '{"tool_name":"Bash","tool_input":{"command":"mkdir -p '"$HOME"'/.claude/cache/x"}}'

expect_allow "cp inside project (src and dst both in zone)" \
  '{"tool_name":"Bash","tool_input":{"command":"cp /test/project/scratch/foo.txt /test/project/data/foo.txt"}}'

# Read-only commands that mention out-of-zone paths must still pass —
# the zone check is gated on write-intent.

expect_allow "ls /etc (read-only, no write-intent)" \
  '{"tool_name":"Bash","tool_input":{"command":"ls /etc"}}'

expect_allow "find ~/some-dir (read-only without -delete/-exec)" \
  '{"tool_name":"Bash","tool_input":{"command":"find ~/some-dir -type f"}}'

expect_allow "execute binary outside zone (~/.local/bin/pnpm --version)" \
  '{"tool_name":"Bash","tool_input":{"command":"~/.local/bin/pnpm --version"}}'

# Substring false-positive guards (carry-over from STMT_START rule):
# `bash scripts/install-hooks.sh` must still ALLOW because `install` is
# inside the filename, not at a statement start. The new zone check
# inherits the STMT_START anchor so it also doesn't fire on substrings.

expect_allow "bash scripts/install-something.sh (install is a substring of the filename)" \
  '{"tool_name":"Bash","tool_input":{"command":"bash git_modules/claude-tools/scripts/install-hooks.sh"}}'

echo "=== Layered config files (default + user + project) ==="
# Exercise the three-file concatenation pattern: shipped default + user-wide
# $HOME/.claude/.path-guard + project $CLAUDE_PROJECT_DIR/.path-guard. The
# shared layered_run helper writes each layer's contents to a fresh temp dir
# and runs the hook with the matching env-var overrides.

layered_block() {
  local label="$1" default_cfg="$2" user_cfg="$3" project_cfg="$4" input="$5"
  layered_run --hook "$HOOK" --kind path-guard \
    --default "$default_cfg" --user "$user_cfg" --project "$project_cfg" \
    --input "$input"
  if [ "$HOOK_RC" -eq 2 ]; then ok "$label"
  else fail "$label — expected BLOCK (exit 2), got exit $HOOK_RC (stderr='$HOOK_STDERR')"; fi
}

layered_allow() {
  local label="$1" default_cfg="$2" user_cfg="$3" project_cfg="$4" input="$5"
  layered_run --hook "$HOOK" --kind path-guard \
    --default "$default_cfg" --user "$user_cfg" --project "$project_cfg" \
    --input "$input"
  if [ "$HOOK_RC" -eq 0 ]; then ok "$label"
  else fail "$label — expected ALLOW (exit 0), got exit $HOOK_RC (stderr='$HOOK_STDERR')"; fi
}

# All file_path values are relative basenames — the hook prepends
# $CLAUDE_PROJECT_DIR (a temp dir owned by the helper) so the zone check
# passes and only the [secret] / [protected] config rules drive the result.

# Default layer [secret] blocks both Read and Write of a matching path.
layered_block "default [secret]: Read blocked" \
  $'[secret]\n.layered-def-secret' "" "" \
  '{"tool_name":"Read","tool_input":{"file_path":".layered-def-secret"}}'

layered_block "default [secret]: Edit blocked" \
  $'[secret]\n.layered-def-secret' "" "" \
  '{"tool_name":"Edit","tool_input":{"file_path":".layered-def-secret","old_string":"a","new_string":"b"}}'

# Default layer [protected] blocks Edit only (Read still allowed).
layered_block "default [protected]: Edit blocked" \
  $'[protected]\n.layered-def-prot' "" "" \
  '{"tool_name":"Edit","tool_input":{"file_path":".layered-def-prot","old_string":"a","new_string":"b"}}'

layered_allow "default [protected]: Read allowed" \
  $'[protected]\n.layered-def-prot' "" "" \
  '{"tool_name":"Read","tool_input":{"file_path":".layered-def-prot"}}'

# User-wide layer ($HOME/.claude/.path-guard).
layered_block "user [secret]: Read blocked" \
  "" $'[secret]\n.layered-user-secret' "" \
  '{"tool_name":"Read","tool_input":{"file_path":".layered-user-secret"}}'

layered_block "user [protected]: Edit blocked" \
  "" $'[protected]\n.layered-user-prot' "" \
  '{"tool_name":"Edit","tool_input":{"file_path":".layered-user-prot","old_string":"a","new_string":"b"}}'

# Project layer ($CLAUDE_PROJECT_DIR/.path-guard).
layered_block "project [secret]: Read blocked" \
  "" "" $'[secret]\n.layered-proj-secret' \
  '{"tool_name":"Read","tool_input":{"file_path":".layered-proj-secret"}}'

layered_block "project [protected]: Edit blocked" \
  "" "" $'[protected]\n.layered-proj-prot' \
  '{"tool_name":"Edit","tool_input":{"file_path":".layered-proj-prot","old_string":"a","new_string":"b"}}'

# All three layers loaded simultaneously: each layer's rules are honoured.
ALL_DEF=$'[secret]\n.three-layer-def-sec'
ALL_USER=$'[protected]\n.three-layer-user-prot'
ALL_PROJ=$'[secret]\n.three-layer-proj-sec'

layered_block "three layers: default [secret] active" \
  "$ALL_DEF" "$ALL_USER" "$ALL_PROJ" \
  '{"tool_name":"Read","tool_input":{"file_path":".three-layer-def-sec"}}'

layered_block "three layers: user [protected] active" \
  "$ALL_DEF" "$ALL_USER" "$ALL_PROJ" \
  '{"tool_name":"Edit","tool_input":{"file_path":".three-layer-user-prot","old_string":"a","new_string":"b"}}'

layered_block "three layers: project [secret] active" \
  "$ALL_DEF" "$ALL_USER" "$ALL_PROJ" \
  '{"tool_name":"Read","tool_input":{"file_path":".three-layer-proj-sec"}}'

# Section context does not leak across files: untagged lines (no header) are
# discarded by path-guard's load_config. A file that starts with a bare
# pattern (no [secret]/[protected] header) contributes nothing, regardless
# of which section the prior file ended in.
layered_allow "section context does not leak: untagged user line ignored" \
  $'[secret]\n.def-leak-sec' $'.user-no-header' "" \
  '{"tool_name":"Read","tool_input":{"file_path":".user-no-header"}}'

# But a header in the same file still routes patterns correctly.
layered_block "section context: user [secret] section routes its patterns" \
  "" $'[secret]\n.user-with-header' "" \
  '{"tool_name":"Read","tool_input":{"file_path":".user-with-header"}}'

# Empty layer files load without error and contribute nothing.
layered_allow "empty default file: nothing blocked" \
  "" "" "" \
  '{"tool_name":"Edit","tool_input":{"file_path":".any-relative-file","old_string":"a","new_string":"b"}}'

echo "=== chmod / chown / chattr attacks on protected files ==="
# Defence-in-depth: an attacker who can't modify a hook's contents could
# disable it by stripping the executable bit. WRITE_CMDS_RE in the
# path-guard Bash backstop includes \bchmod\b, \bchown\b, \bchattr\b, so
# any of these naming a protected path on the same line is treated as a
# write and blocked. Pin that behaviour here.

expect_block "chmod -x on path-guard hook.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"chmod -x /test/project/.claude/hooks/path-guard/hook.sh"}}'

expect_block "chmod 644 on bash-guard hook.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"chmod 644 /test/project/.claude/hooks/bash-guard/hook.sh"}}'

expect_block "chmod a-x on hook.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"chmod a-x /test/project/.claude/hooks/always-allow/hook.sh"}}'

expect_block "chmod 000 on settings.json" \
  '{"tool_name":"Bash","tool_input":{"command":"chmod 000 /test/project/.claude/settings.json"}}'

expect_block "chmod 000 on CLAUDE.md" \
  '{"tool_name":"Bash","tool_input":{"command":"chmod 000 /test/project/CLAUDE.md"}}'

expect_block "chown other:other on hook.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"chown nobody:nobody /test/project/.claude/hooks/path-guard/hook.sh"}}'

expect_block "chattr +i on hook.sh (lock attribute)" \
  '{"tool_name":"Bash","tool_input":{"command":"chattr +i /test/project/.claude/hooks/path-guard/hook.sh"}}'

# chmod on a non-protected file inside the project is allowed.
expect_allow "chmod +x on non-protected script (allowed)" \
  '{"tool_name":"Bash","tool_input":{"command":"chmod +x /test/project/scripts/my-new-script.sh"}}'

echo "=== Symlink resolution: writes follow realpath -m to protected target ==="
# BUGS.md gap: existing probes test literal path text only. This section
# creates real on-disk symlinks pointing at protected destinations and
# verifies the hook follows them via realpath -m before the rule check.
# The symlink targets do not need to exist on disk — path-guard's
# normalize_path applies `realpath -m` which canonicalises missing
# components without failing.

SYMLINK_DIR=$(mktemp -d)

# Symlink at <tmp>/redirect-settings → /test/project/.claude/settings.json.
# Direct Edit on a settings.json path is already blocked elsewhere; this
# variant proves the block fires through a real symlink, not just on a
# literal path string.
ln -s "/test/project/.claude/settings.json" "$SYMLINK_DIR/redirect-settings"

expect_block "Edit through real symlink to project settings.json" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$SYMLINK_DIR/redirect-settings"'","old_string":"a","new_string":"b"}}'

expect_block "Write through real symlink to project settings.json" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$SYMLINK_DIR/redirect-settings"'","content":"x"}}'

# Bash redirect through the same symlink.
expect_block "Bash redirect '>' through real symlink to protected file" \
  '{"tool_name":"Bash","tool_input":{"command":"echo x > '"$SYMLINK_DIR/redirect-settings"'"}}'

# Symlink pointing at a project hook.sh — also protected via the path-guard
# default rules.
ln -s "/test/project/.claude/hooks/bash-guard/hook.sh" "$SYMLINK_DIR/redirect-hook"

expect_block "Edit through symlink to bash-guard hook.sh" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$SYMLINK_DIR/redirect-hook"'","old_string":"a","new_string":"b"}}'

# Symlink chain: <tmp>/chain1 → <tmp>/chain2 → /test/project/CLAUDE.md.
# realpath -m follows the whole chain.
ln -s "/test/project/CLAUDE.md" "$SYMLINK_DIR/chain2"
ln -s "$SYMLINK_DIR/chain2"      "$SYMLINK_DIR/chain1"

expect_block "Edit through symlink chain to CLAUDE.md" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$SYMLINK_DIR/chain1"'","old_string":"a","new_string":"b"}}'

# Symlink pointing at a NON-protected path inside the project zone — must
# remain allowed.
ln -s "/test/project/src/app.cs" "$SYMLINK_DIR/redirect-allowed"

expect_allow "Edit through symlink to non-protected file inside project" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$SYMLINK_DIR/redirect-allowed"'","old_string":"a","new_string":"b"}}'

# Symlink pointing OUT of the allowed zones — zone check blocks regardless
# of [protected] rules.
ln -s "/etc/passwd" "$SYMLINK_DIR/redirect-out-of-zone"

expect_block "Edit through symlink to /etc/passwd (zone check)" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$SYMLINK_DIR/redirect-out-of-zone"'","old_string":"a","new_string":"b"}}'

rm -rf "$SYMLINK_DIR"

echo "=== Repeat-suppression on block_write (CLAUDE_SESSION_SCRATCH set) ==="
# When CLAUDE_SESSION_SCRATCH points at a real dir, the first write-block emits
# the full scratch+mv workflow and touches a marker file; subsequent blocks
# emit a one-liner pointing back. Tests that don't set the env always see the
# full message (above), so this section pins the optional shorter form.

REP_TMP=$(mktemp -d)
REP_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/test/project/.claude/settings.json","old_string":"a","new_string":"b"}}'

FIRST_ERR=$(printf '%s' "$REP_INPUT" | \
  PATH_GUARD_HOOK_DIR="$HOOK_DIR" \
  CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" \
  CLAUDE_SESSION_SCRATCH="$REP_TMP" \
  bash "$HOOK" 2>&1 >/dev/null || true)
if echo "$FIRST_ERR" | grep -q "To proceed: write to" && [ -f "$REP_TMP/.path-guard-seen" ]; then
  ok "first block: full workflow message + .path-guard-seen marker created"
else
  fail "first block: full workflow message + marker (err='$FIRST_ERR'; marker=$([ -f "$REP_TMP/.path-guard-seen" ] && echo yes || echo no))"
fi

SECOND_ERR=$(printf '%s' "$REP_INPUT" | \
  PATH_GUARD_HOOK_DIR="$HOOK_DIR" \
  CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" \
  CLAUDE_SESSION_SCRATCH="$REP_TMP" \
  bash "$HOOK" 2>&1 >/dev/null || true)
if echo "$SECOND_ERR" | grep -q "See earlier path-guard message" \
&& ! echo "$SECOND_ERR" | grep -q "To proceed:"; then
  ok "second block: short message points back at earlier guidance"
else
  fail "second block: short message (err='$SECOND_ERR')"
fi

rm -rf "$REP_TMP"

echo ""
if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES test.sh case(s) failed." >&2
  exit 1
fi
echo "All test.sh cases passed."

echo ""
echo "=== Running adversarial probes (test-jailbreak.sh) ==="
bash "$HOOK_DIR/test-jailbreak.sh" "$HOOK"
