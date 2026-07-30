# Memory compiler wiring (opt-in)

Both coding agents on a machine can flush their conversations into the
[claude-memory-compiler](https://github.com/nmogil/claude-memory-compiler)
knowledge base (daily logs → compiled concept articles, injected back into
future sessions). This doc covers replicating that wiring on a new device.
It is **not** applied by `setup.sh` / `setup-linux.sh`; you install it
deliberately.

## Prerequisites

- A checkout of the compiler, by default at
  `~/github_repos/personal/claude-memory-compiler` (`./dot repos clone` puts it
  there). Override the location with `PI_MEMORY_COMPILER_DIR` in
  `~/.config/dotfiles/local.env`.
- `uv` and `jq` (both in `packages/`).

## Claude Code

```bash
./dot claude hooks            # dry-run: print the settings.json it would write
./dot claude hooks --apply    # merge hooks into ~/.claude/settings.json (backs up first)
./dot claude hooks --check    # verify wiring + compiler checkout
```

This wires three hooks in `~/.claude/settings.json`, preserving any unrelated
hooks and settings already there:

| Event | Script | What it does |
|-------|--------|--------------|
| `SessionStart` | `hooks/session-start.py` | Injects the knowledge-base index into context |
| `PreCompact` | `hooks/pre-compact.py` | Captures the transcript before auto-compaction |
| `SessionEnd` | `hooks/session-end.py` | Captures the transcript, spawns a background flush into the daily log |

Compilation of daily logs into knowledge articles is handled by the compiler
itself (opportunistically after 6 PM local, or `uv run python
scripts/compile.py` manually) — nothing extra to wire here.

## Pi

Pi capture ships with the scaffold (see
[`pi-agent-setup.md`](pi-agent-setup.md)):
`agent/extensions/pi-memory-compiler.ts` listens for `session_shutdown` /
`session_compact` and spawns the compiler's `scripts/pi_session.py`. After
`./dot pi scaffold --apply`, activate it with:

```bash
cp "$DOTFILES_PI_SCAFFOLD_DIR/agent/memory-compiler.example.json" \
   ~/.pi/agent/memory-compiler.json   # then edit compilerDir if non-default
```

Note the asymmetry: Pi only captures on shutdown/compact — it does not inject
the knowledge-base index at session start the way the Claude Code
`SessionStart` hook does.
