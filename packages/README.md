# packages/

Package manifests, split by role. These are **documentation + input for
`./dot packages check`** — they are not yet the source of truth for install
(the setup scripts still hold the authoritative lists). Keep them in sync when
you change what the setup scripts install.

| File | Scope |
|------|-------|
| `apt.base` | Core Debian/Ubuntu packages (shell, CLI, media, Python) |
| `apt.agent` | Debian/Ubuntu packages for agent/dev tooling (gh, nodejs) |
| `npm.global` | Global npm CLIs (Claude Code, Codex, Pi, Hunk, Obsidian headless) |
| `Brewfile` note | macOS packages live in the repo-root [`../Brewfile`](../Brewfile) |

Format: one package per line; `#` comments and blank lines ignored.

macOS packages intentionally stay in the top-level `Brewfile` so `brew bundle`
and `./setup.sh` keep working unchanged. Do not move it.

Check what's installed vs declared:

```bash
./dot packages check
```
