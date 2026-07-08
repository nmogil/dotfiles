# Pi agent setup (opt-in)

An opt-in scaffold for a [Pi coding agent](https://github.com/mariozechner/pi)
workspace, adapted from [dmmulroy/.dotfiles](https://github.com/dmmulroy/dotfiles).
It is **not** applied by `setup.sh` / `setup-linux.sh`; you install it deliberately.

## TL;DR

```bash
./dot pi doctor               # read-only checks
./dot pi scaffold --dry-run   # preview copy into ~/.pi
./dot pi scaffold --apply     # copy scaffold (skips existing; --force backs up)
./dot pi install              # install the pi CLI (Vite+ flow; prompts first)
```

The scaffold lives in [`templates/pi/`](../templates/pi/). Its own
[README](../templates/pi/README.md) covers the post-copy manual steps
(`npm install`, copy the `*.example.json` files, `pi /reload`).

The example JSON field names are intentionally conservative and may need to be
adjusted for the Pi version you install. Treat them as a starting template, not
an authoritative Pi schema.

## What was adapted (safe, generic)

| File | Notes |
|------|-------|
| `.gitignore` | Ignores `node_modules`, runtime `settings.json`/`mcp.json`, auth/session state |
| `README.md` | Rewritten for this repo; opt-in framing |
| `package.json`, `tsconfig.json` | TS workspace for selected safe extensions; no lockfile vendored |
| `agent/extensions/git-interceptor.ts` | Portable safety guard: prevents git editor hangs and blocks `--no-verify` |
| `agent/extensions/worker-configuration-guard.ts` | Portable Cloudflare/Wrangler guard for generated `worker-configuration.d.ts` |
| `agent/extensions/pi-cloak/`, `agent/cloak.json` | Generic redaction extension + config; no real secrets |
| `agent/extensions/pi-memory-compiler.ts`, `agent/memory-compiler.example.json` | Optional Obsidian memory capture through `claude-memory-compiler` |
| `agent/extensions/save-md/` | Utility command `/save-md <name>` |
| `agent/skills/{code-review,coding-standards,diagnosing-bugs,domain-modeling,handoff,herdr,tdd,tech-spec}` | Selected relevant engineering skills |
| `agent/skills/{improve-codebase-architecture,prototype,writing-great-skills,grilling}` | Selected personal/workflow skills: architecture scans, throwaway prototypes, skill authoring, and design stress-tests |
| `agent/themes/catppuccin-macchiato.json` | Public Catppuccin palette, updated to Pi's current `colors` schema |
| `agent/settings.example.json` | Placeholders only (`REPLACE_ME_*`); real file is gitignored |
| `agent/mcp.example.json` | Local/disabled placeholder servers only |

## What was intentionally excluded

Copied nothing that is private, user-specific, or runtime state:

- **`agent/mcp.json` with private URLs** — the source referenced private
  endpoints (`exe.mulroy.ai`, `cfdata.org`) and a `UIDOTSH_TOKEN`. Not copied.
  The example uses `REPLACE_ME` placeholders and stays disabled.
- **`opencode-cloudflare` extension** and any private gateway / Cloudflare
  account overlay — not copied.
- **Private model IDs and provider endpoints** — `settings.example.json` uses
  generic placeholders; supply your own.
- **Auth / session / cache state** — never copied; gitignored in the scaffold.
- **Live memory compiler config** — `agent/memory-compiler.json` is gitignored;
  the example contains only the local repo path and no credentials.
- **The full personal extension set and `.agents` skills** — only selected
  portable extensions/skills are adapted. The private/opinionated remainder
  stays out unless explicitly reviewed and added later.

## Installing the pi CLI

Per dmmulroy's README, via [Vite+](https://vite.plus):

```bash
curl -fsSL https://vite.plus | bash
vp install -g @earendil-works/pi-coding-agent
```

`./dot pi install` prints these and prompts before running them. Because pi is
installed via `vp` (not `npm -g`), it is **not** listed in `packages/npm.global`
— see the note there.

## Safety checks

`./dot pi doctor` verifies: the scaffold is present, `~/.pi` state (if any) has
no runtime auth files tracked by git, and the scaffold is free of known private
strings / live secret shapes. `git diff --check` and `./dot doctor` also apply.
