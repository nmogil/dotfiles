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
| `agent/settings.example.json` | Credential-free defaults and the reviewed model allowlist |
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
pi /reload
```

From the dotfiles repository root, install the reviewed Pi delegation packages:

```bash
./dot pi subagents --dry-run
./dot pi subagents --apply    # pinned pi-subagents + pi-herdr; no pi-herd mirror
./dot pi subagents --check
```

Pi executes directly by default. Delegation and any policy-authorized runtime
fallback follow `agent/skills/subagent-routing/SKILL.md`.

## Installing the Pi CLI itself

Not installed by default. The npm distribution is required because Vite+'s
global Pi layout currently breaks runtime imports used by subagent extensions.
When you want it:

```bash
./dot pi install     # installs pinned npm Pi and migrates an existing Vite+ Pi
# equivalent install command:
#   npm install -g @earendil-works/pi-coding-agent@0.80.6
```

See `docs/pi-agent-setup.md` in the repo root for installation, operation, and
what was adapted or intentionally excluded.
