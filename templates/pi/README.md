# Pi agent workspace (opt-in scaffold)

This directory is an **inert, opt-in scaffold** for a [Pi coding agent]
(`@earendil-works/pi-coding-agent`) workspace, adapted from
[dmmulroy/.dotfiles](https://github.com/dmmulroy/dotfiles). Nothing here runs
until you deliberately install it into `~/.pi` (see below). It is **not** wired
into `setup.sh` / `setup-linux.sh`.

Everything here is generic and safe to commit: no provider endpoints, no model
IDs, no tokens, no private MCP servers. The real config lives in files you
create locally from the `*.example.json` templates and which stay gitignored.

## What's here

| Path | Purpose |
|------|---------|
| `package.json`, `tsconfig.json` | TypeScript workspace for Pi extensions |
| `agent/extensions/git-interceptor.ts` | Prevents git editor hangs and blocks `--no-verify` hook bypasses |
| `agent/extensions/worker-configuration-guard.ts` | Blocks manual edits to generated Cloudflare `worker-configuration.d.ts` files |
| `agent/extensions/pi-cloak/` | Redacts configured secret-like values from Pi read output |
| `agent/extensions/save-md/` | Adds `/save-md <name>` to save the latest assistant response as Markdown |
| `agent/skills/` | Selected engineering and personal workflow skills adapted from dmmulroy's setup, not the full personal library |
| `agent/cloak.json` | Secret-masking patterns (masks tokens/keys in the TUI) |
| `agent/themes/catppuccin-macchiato.json` | A theme (public Catppuccin palette) |
| `agent/settings.example.json` | Template settings — **generic placeholders only** |
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
pi /reload
```

## Installing the Pi CLI itself

Not installed by default. When you want it:

```bash
./dot pi install     # prints/runs the documented Vite+ install flow
# equivalently, per dmmulroy's README:
#   curl -fsSL https://vite.plus | bash
#   vp install -g @earendil-works/pi-coding-agent
```

See `docs/pi-agent-setup.md` in the repo root for what was adapted vs.
intentionally excluded from dmmulroy's setup.
