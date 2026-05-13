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

echo ""
if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES test.sh case(s) failed." >&2
  exit 1
fi
echo "All test.sh cases passed."

echo ""
echo "=== Running adversarial probes (test-jailbreak.sh) ==="
bash "$HOOK_DIR/test-jailbreak.sh" "$HOOK"
