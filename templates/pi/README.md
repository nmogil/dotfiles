# Pi agent workspace (opt-in scaffold)

This directory is an **inert, opt-in scaffold** for a [Pi coding agent]
(`@earendil-works/pi-coding-agent`) workspace, adapted from
[dmmulroy/.dotfiles](https://github.com/dmmulroy/dotfiles). Nothing here runs
until you deliberately install it into `~/.pi` (see below). It is **not** wired
into `setup.sh` / `setup-linux.sh`.

Everything here is safe to commit: no private provider endpoints, tokens, or
private MCP servers. It does include reviewed public model IDs for deterministic
subagent routing. Credential-bearing live config stays gitignored.

**Provenance:** this scaffold is adapted from a third party and its license is
unresolved — see [`docs/licensing.md`](../../docs/licensing.md) before reusing it.

## What's here

| Path | Purpose |
|------|---------|
| `package.json`, `tsconfig.json` | TypeScript workspace for Pi extensions |
| `agent/extensions/account-profile-indicator.ts` | Shows the active credential profile persistently in Pi's footer |
| `agent/extensions/git-interceptor.ts` | Prevents git editor hangs and blocks `--no-verify` hook bypasses |
| `agent/extensions/worker-configuration-guard.ts` | Blocks manual edits to generated Cloudflare `worker-configuration.d.ts` files |
| `agent/extensions/pi-cloak/` | Redacts configured secret-like values from Pi read output |
| `agent/extensions/pi-memory-compiler.ts` | Queues Pi session JSONL capture into the Obsidian memory compiler on compact/shutdown |
| `agent/extensions/save-md/` | Adds `/save-md <name>` to save the latest assistant response as Markdown |
| `agent/skills/` | Selected engineering skills plus the Pi-first subagent/model routing policy |
| `agent/agents/` | Task-specific Sol, Opus, Sonnet, and Fable Pi worker profiles |
| `agent/subagents.json` | Concurrency, scope, role-list, and FleetView defaults |
| `agent/agent-tool-description.md` | Model-facing role selection guidance for the `Agent` tool |
| `agent/cloak.json` | Secret-masking patterns (masks tokens/keys in the TUI) |
| `agent/themes/catppuccin-macchiato.json` | A theme (public Catppuccin palette) |
| `agent/settings.example.json` | Credential-free defaults, reviewed model allowlist, and pinned Codex compaction package |
| `agent/pi-codex-compaction.json` | Enables native Codex compaction at 90% context usage with a visible notification |
| `agent/models.work.example.json` | Generic work-profile model detail names without credentials or model-ID changes |
| `agent/mcp.example.json` | Template MCP config — **local/commented examples only** |

## Install (opt-in)

From the repo root, the guided installer copies this scaffold to
`${PI_HOME:-$HOME/.pi}` without overwriting existing files:

```bash
./dot pi scaffold --dry-run   # preview what would be copied
./dot pi scaffold --apply     # actually copy (backs up on conflict)
```

Then, manually (the installer will not do these for you):

```bash
cd "${PI_HOME:-$HOME/.pi}"
npm install
cp agent/settings.example.json agent/settings.json   # then edit: add your provider/model
cp agent/mcp.example.json      agent/mcp.json         # then edit: add your MCP servers
cp agent/memory-compiler.example.json agent/memory-compiler.json  # optional Obsidian memory capture
# agent/pi-codex-compaction.json is ready as copied; settings.example.json pins its package
pi /reload
```

From the dotfiles repository root, optionally prepare separate personal and
work profiles, then install the reviewed Pi delegation packages. A private
`DOTFILES_PI_WORK_PROFILE_SLUG` value can name the work profile locally:

```bash
./dot pi profiles --dry-run
./dot pi profiles --apply
./dot pi profiles --check

./dot pi subagents --dry-run
./dot pi subagents --apply    # pinned pi-subagents + pi-herdr; no pi-herd mirror
./dot pi subagents --check
```

Pi executes directly by default. Delegation and any policy-authorized runtime
fallback follow `agent/skills/subagent-routing/SKILL.md`. In-process Pi
Subagents inherit the active parent profile. Fresh Pi processes must receive
`PI_CODING_AGENT_DIR` explicitly; bare Claude Code is not an authorized
work-profile fallback because its credentials are independent from Pi.

## Installing the Pi CLI itself

Not installed by default. The npm distribution is required because Vite+'s
global Pi layout currently breaks runtime imports used by subagent extensions.
When you want it:

```bash
./dot pi install     # installs pinned npm Pi and migrates an existing Vite+ Pi
# equivalent install command:
#   npm install -g @earendil-works/pi-coding-agent@0.81.1
```

See `docs/pi-agent-setup.md` in the repo root for installation, operation, and
what was adapted or intentionally excluded.
