# Claude Code — claude-tools/ instructions

**Archival — pending removal.** This submodule contains legacy bash hooks (PreToolUse / PostToolUse / SessionStart / SessionEnd) superseded by the C# hook-daemon at `src/tools/hook/`. Bash hook bodies are no longer wired in production — `settings.json` routes every event through the C# shim instead.

A handful of production paths still treat this submodule as a fallback config source or test-fixture path namespace:

- `PathGuardHandler` + daemon `Program.cs` — fallback path-construction reads default rules from here.
- `policy.default.json` — allows execution of bash hook tests under this submodule.
- Regression test corpus — several `PathGuard*` scenarios use submodule paths as fixtures.
- `.path-guard` — rules protect submodule paths via realpath mirroring.

These dependencies are tracked at [`docs/plans/claude-tools-submodule-removal.md`](../../docs/plans/claude-tools-submodule-removal.md); once migrated, the submodule itself goes.

**Until the migration ships, don't make behavioural changes here** — they wouldn't reach production (bash hooks aren't wired) and they fight the planned removal. If you need to change hook behaviour, the active home is `src/tools/hook/` per [`src/tools/hook/CLAUDE.md`](../../src/tools/hook/CLAUDE.md).
