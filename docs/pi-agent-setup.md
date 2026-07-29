# Pi agent setup (opt-in)

An opt-in installer for a [Pi coding agent](https://github.com/mariozechner/pi)
workspace. It is **not** applied by `setup.sh` / `setup-linux.sh`; you install
it deliberately.

The scaffold content itself is **not tracked in this repo**: it was adapted
from [dmmulroy/.dotfiles](https://github.com/dmmulroy/.dotfiles), which grants
no license, so it lives outside the public tree — see
[`licensing.md`](licensing.md). Point `DOTFILES_PI_SCAFFOLD_DIR` in
`~/.config/dotfiles/local.env` at a local checkout of your scaffold (for the
author, a private companion repo); a fork-local `templates/pi/` is used as the
fallback when the variable is unset.

## TL;DR

```bash
./dot pi doctor               # read-only checks
./dot pi scaffold --dry-run   # preview copy into ~/.pi
./dot pi scaffold --apply     # copy scaffold (skips existing; --force backs up)
./dot pi subagents --dry-run  # preview pinned Pi subagent package installation
./dot pi subagents --apply    # install pi-subagents + pi-herdr from reviewed source
./dot pi install              # install pinned npm Pi; migrates Vite+ Pi after confirmation
```

The scaffold's own README covers the post-copy manual steps
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
| `agent/skills/subagent-routing/` | Direct-first delegation, model, placement, and fallback policy |
| `agent/agents/` | Explicit Sol, Opus, Sonnet, and Fable worker profiles selected from the original user goal |
| `agent/subagents.json`, `agent/agent-tool-description.md` | Deterministic subagent defaults and model-facing role guidance |
| `scripts/setup-pi-subagents.sh` | Opt-in installer for pinned `pi-subagents` and `pi-herdr` source; excludes incomplete mirrors |
| `agent/themes/catppuccin-macchiato.json` | Public Catppuccin palette, updated to Pi's current `colors` schema |
| `agent/settings.example.json` | Placeholders only (`REPLACE_ME_*`); real file is gitignored |
| `agent/mcp.example.json` | Local/disabled placeholder servers only |

## What was intentionally excluded

Copied nothing that is private, user-specific, or runtime state:

- **`agent/mcp.json` with private URLs** — the source referenced private
  provider endpoints and an auth token. Not copied. The example uses
  `REPLACE_ME` placeholders and stays disabled. `./dot pi doctor` rejects
  generic secret shapes in the scaffold and appends any project-specific
  private patterns from a local, gitignored blocklist
  (`DOTFILES_PI_BLOCKLIST`; see `config/dotfiles/local.env.example`).
- **`opencode-cloudflare` extension** and any private gateway / Cloudflare
  account overlay — not copied.
- **Private model IDs and provider endpoints** — the scaffold includes only the
  reviewed public model IDs required by the routing policy. Custom/private
  providers and credentials remain local.
- **Auth / session / cache state** — never copied; gitignored in the scaffold.
- **Live memory compiler config** — `agent/memory-compiler.json` is gitignored;
  the example contains only the local repo path and no credentials.
- **The full personal extension set and `.agents` skills** — only selected
  portable extensions/skills are adapted. The private/opinionated remainder
  stays out unless explicitly reviewed and added later.

## Installing Pi subagents

The optional subagent stack is pinned to reviewed `WeShipWork/threeonefour`
commit `7f86a2931f83b68f7915fd132a026bb8fa76ae97`. Apply the scaffold first; the
package installer refuses to continue unless the routing policy, profiles, and
subagent defaults are present. It keeps a commit-pinned, clean checkout under
`~/.local/share/pi-packages`, installs production dependencies from the
committed lockfile, and adds only `pi-subagents` and `pi-herdr` to Pi:

```bash
./dot pi subagents --dry-run
./dot pi subagents --apply
./dot pi subagents --check
```

`PI_HOME` and `PI_CODING_AGENT_DIR` overrides are honored consistently by the
scaffold and package checks. `pi-herd` is deliberately excluded until its
transcript mirror is complete.
The routing skill is the policy source of truth. Pi executes directly by
default. It delegates only on explicit request or when parallelism, isolation,
specialist context, or independent consequential review materially helps.
Claude Code fallback is policy-authorized only for qualifying Claude-in-Pi
runtime failures and only when tool access permits; assignments, cwd, and
verification are preserved, and the actual runtime/model is disclosed. Poor
output is reviewed, not treated as runtime failure.

## Installing the pi CLI

Install the tested npm distribution:

```bash
npm install -g @earendil-works/pi-coding-agent@0.80.6
```

`./dot pi install` prints the command and prompts before running it. It requires
Node.js >=22.19 and npm outside Vite+'s managed runtime (system/NodeSource on
Linux or Homebrew on macOS). If the system global prefix is not writable, the
installer uses the user-owned `~/.local` prefix. After the npm executable passes a version check,
it removes only Vite+'s global Pi package
with `vp remove -g @earendil-works/pi-coding-agent`; Vite+ itself remains
available for project tooling.

The npm layout is intentional. Pi 0.80.6 installed globally through Vite+ was
verified to fail runtime imports used by `pi-subagents` and other extensions,
while the same Pi version installed through npm loaded the pinned source stack.
Pi is therefore listed in `packages/npm.global`.

## Safety checks

`./dot pi doctor` verifies: the scaffold and direct-first routing assets are present,
`~/.pi` state (if any) has no runtime auth files tracked by git, and the scaffold
is free of known private strings / live secret shapes. `./dot pi subagents
--check` verifies the commit-pinned, clean checkout and installed package entries.
`git diff --check` and `./dot doctor` also apply.
