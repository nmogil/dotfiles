# Dotfiles

My personal development environment setup. One command on macOS, one command on a Linux VPS.

## Quick Start

`./dot` is the control surface — a thin wrapper over the scripts below. Run
`./dot help` for all commands and `./dot doctor` for a read-only health check.
The direct script commands still work if you prefer them.

**macOS:**
```bash
git clone https://github.com/nmogil/dotfiles.git ~/dotfiles
cd ~/dotfiles
./dot setup mac            # or: ./setup.sh
```

**Linux (Debian/Ubuntu VPS):**
```bash
git clone https://github.com/nmogil/dotfiles.git ~/dotfiles
cd ~/dotfiles
./dot setup linux          # dev environment (or: ./setup-linux.sh)
gh auth login              # then authenticate GitHub CLI
cp repos.txt.example repos.txt && $EDITOR repos.txt
./dot repos clone          # bulk-clone your repos (or: ./clone-repos.sh)
./dot server harden        # optional: Tailscale + UFW + auto-upgrades
./dot obsidian sync        # optional: Obsidian Headless Sync
./dot doctor               # verify the environment (read-only)
herdr                      # launch the agent cockpit
```

See [`AGENTS.md`](AGENTS.md) for where to edit things and safety rules.

## What's Included

| File | Description |
|------|-------------|
| `dot` | Control surface — thin wrapper over the setup scripts (`./dot help`) |
| `scripts/doctor.sh` | Read-only environment health check (`./dot doctor`) |
| `AGENTS.md` | Where to edit things + safety rules for agents/humans |
| `packages/` | Package manifests split by role + `./dot packages check` |
| `docs/chezmoi-plan.md` | Planned (not yet applied) chezmoi migration |
| `templates/pi/` | Opt-in Pi workspace plus Pi-first subagent/model routing (`./dot pi ...`, `docs/pi-agent-setup.md`) |
| `Brewfile` | Homebrew packages and casks (macOS) |
| `.zshrc` | Zsh configuration with Oh My Zsh |
| `.p10k.zsh` | Powerlevel10k theme configuration |
| `.gitconfig` | Git settings |
| `setup.sh` | macOS installation script |
| `setup-linux.sh` | Debian/Ubuntu installation script (headless-friendly) |
| `harden-vps.sh` | Optional VPS hardening: unattended-upgrades, Tailscale, UFW |
| `setup-obsidian-sync.sh` | Optional: Obsidian Headless Sync (npm install, login, systemd user unit) |
| `clone-repos.sh` | Bulk-clone repos from `repos.txt` into `~/github_repos` workstream buckets via `gh` |
| `repos.txt.example` | Template for `repos.txt` (gitignored — personal list) |
| `config/hunk/config.toml` | Hunk diff-review TUI defaults (copied to `~/.config/hunk/`) |
| `config/ghostty/config` | Ghostty terminal config (copied to `~/Library/Application Support/com.mitchellh.ghostty/`) |
| `server/` | VPS memory guardrails (systemd drop-ins, zram, sysctl) + Herdr helper scripts |
| `server/scripts/patch-herdr-codex-detection.sh` | Patches Herdr's Codex detection manifest so update/hook prompts show as blocked |

## What the Setup Script Does

1. Installs **Xcode Command Line Tools** (if needed)
2. Installs **Homebrew** (Intel & Apple Silicon compatible)
3. Installs all packages from `Brewfile`:
   - CLI tools: git, gh, node, python, flyctl, etc.
   - Apps: Arc, Ghostty, Obsidian, Claude Code, HiddenBar, ngrok
4. Installs **Oh My Zsh** with plugins:
   - zsh-autosuggestions
   - zsh-syntax-highlighting
   - web-search
5. Installs **Powerlevel10k** theme
6. Downloads **MesloLGS NF** fonts automatically
7. Copies all config files (with backups), including the Ghostty terminal config
8. Optionally configures git user name/email
9. Optionally generates SSH key for GitHub
10. Optionally applies macOS settings (Finder tweaks, faster key repeat, etc.)

## Customization

### Adding More Brew Packages

Edit `Brewfile` and uncomment or add packages:

```ruby
brew "fzf"          # Fuzzy finder
brew "ripgrep"      # Fast grep
cask "visual-studio-code"
```

### Changing Zsh Plugins

Edit the `plugins` line in `.zshrc`:

```bash
plugins=(git zsh-autosuggestions zsh-syntax-highlighting web-search)
```

### Re-running Powerlevel10k Configuration

```bash
p10k configure
```

## What the Linux Setup Script Does

On launch, the script asks whether to run in **Full** mode (install everything,
default) or **Custom** mode (prompt before each component group). Either way,
all output is timestamped and tee'd to `~/.dotfiles-setup-linux-<timestamp>.log`
for post-mortem debugging. On any failure, the script prints the failed line
number and the log path.

Component groups (each is `[Y/n]` in Custom mode):

1. **Base tools** — `build-essential`, `curl`, `git`, `zsh` (always installed)
2. **Full system upgrade** — `apt upgrade -y`
3. **Core CLI tools** — `tmux`, `fd`, `fzf`, `jq`, `ripgrep`, `zoxide`, `micro`, `bat`, `git-delta`, `just`, `neofetch`
4. **Media tools** — `ffmpeg`, `imagemagick`, `ghostscript`, `poppler`, `librsvg`, `p7zip`, `sox`
5. **MesloLGS NF fonts** — for Powerlevel10k (desktop Linux only — useless on a headless VPS)
6. **Python** — `python3`, `pip`, `venv`
7. **uv** — fast Python package/project manager from Astral
8. **GitHub CLI** — `gh` (from official apt repo)
9. **Node.js 22** — pinned via NodeSource (LTS through April 2027)
10. **Bun**
11. **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
12. **Codex CLI** — `npm install -g @openai/codex`
13. **Herdr** — agent session cockpit, official installer (`curl -fsSL https://herdr.dev/install.sh | sh`)
14. **Herdr integrations** — `herdr integration install claude|codex|hermes` (skips agents not on PATH), plus the Codex detection manifest patch and the Hermes `herdr` skill (non-fatal if Hermes isn't installed/authenticated yet)
15. **Hunk** — `npm install -g hunkdiff` diff-review TUI, copies `config/hunk/config.toml`, symlinks the bundled `hunk-review` skill into `~/.claude/skills/`, and installs the Hermes skill (non-fatal)
16. **lazygit** — latest release binary
17. **flyctl**
18. **ngrok** — official apt repo
19. **Docker Compose plugin** — only if `docker` is present
20. **lazydocker** — latest release binary
21. **yazi** — only if `cargo` is present
22. **Oh My Zsh + plugins + Powerlevel10k**
23. **Config files** — copies `.zshrc`, `.p10k.zsh`, `.gitconfig`, `.tmux.conf` (backs up existing)
24. **Default shell** — `chsh` to zsh (prompted)
25. **SSH key** — generates `ed25519` for GitHub (prompted)

Skipped vs macOS: Homebrew, GUI apps (Arc, Obsidian, etc.), MesloLGS fonts
(those live on the local terminal client, not the server), and macOS `defaults`.

## VPS Hardening (Optional)

For a public-internet VPS, run `./harden-vps.sh` after `setup-linux.sh`. Same
logging treatment: timestamped output, tee'd to `~/.dotfiles-harden-vps-<timestamp>.log`,
ERR trap prints the failing line.

Three opt-in steps in a safe order:

1. **Unattended-upgrades** — auto-installs Debian/Ubuntu security patches
2. **Tailscale** — joins the box to your tailnet so SSH can move off the public IP
3. **UFW** — drops all public inbound traffic, allows only the Tailscale interface

The script will not enable UFW until it has verified Tailscale is up and you
have confirmed a working tailnet SSH session — this prevents lock-outs.

After hardening, optionally edit `/etc/ssh/sshd_config` to set
`PasswordAuthentication no` and `PermitRootLogin no` (the script prints the
exact commands but does not run them automatically).

## Pi Agent Scaffold (Optional)

An opt-in [Pi coding agent](https://github.com/mariozechner/pi) workspace,
adapted from [dmmulroy/.dotfiles](https://github.com/dmmulroy/dotfiles). It is
**not** applied by the setup scripts — you install it deliberately. It holds no
private endpoints, tokens, or private MCP servers; reviewed public model IDs are
committed for deterministic subagent routing.

```bash
./dot pi doctor               # read-only checks
./dot pi scaffold --dry-run   # preview copy into ~/.pi (writes nothing)
./dot pi scaffold --apply     # copy scaffold (skips existing; --force backs up)
./dot pi subagents --dry-run  # preview pinned Pi subagent package setup
./dot pi subagents --apply    # install pi-subagents + pi-herdr (not pi-herd)
./dot pi install              # install pinned npm Pi; migrates Vite+ Pi after confirmation
```

The scaffold lives in `templates/pi/`; your real `settings.json` / `mcp.json`
are created locally from the `*.example.json` files and stay gitignored. Its
routing policy selects models from the original user goal, runs every first
subagent through Pi, and uses Claude Code automatically only when the selected
Claude model cannot run in Pi, trying the same model and then Opus 4.8. See
[`docs/pi-agent-setup.md`](docs/pi-agent-setup.md) for the package pin and full
routing details.

## Obsidian Headless Sync (Optional)

For a VPS that should keep an Obsidian vault in sync as a background service,
run `./setup-obsidian-sync.sh` after `setup-linux.sh`. **Requires an active
Obsidian Sync subscription (paid)** — without it, login will fail and there
are no remote vaults to sync.

```bash
./setup-obsidian-sync.sh
```

What it does (each step is idempotent and safe to re-run):

1. Verifies `node` / `npm` are present and confirms the subscription
2. Installs `obsidian-headless` globally via npm (skipped if `ob` already on PATH)
3. Logs in with `ob login` (skipped if `ob sync-list-remote` already succeeds)
4. Picks an existing local vault setup or runs `ob sync-setup --vault <name>` against the local path (default `~/obsidian`)
5. Runs a one-shot `ob sync` to populate the vault
6. Installs a systemd **user** unit (`~/.config/systemd/user/ob-sync.service`) that runs `ob sync --continuous`, enables linger so it survives logout, and `enable --now`s the unit
7. If `~/.hermes/.env` exists, appends or updates `OBSIDIAN_VAULT_PATH` to point at the vault

Manage the sync service:

```bash
systemctl --user status ob-sync
systemctl --user restart ob-sync
systemctl --user stop ob-sync
journalctl --user -u ob-sync -f
```

Docs: <https://help.obsidian.md/sync/headless>

## VPS Repo Layout

The Linux/VPS workflow uses `~/github_repos` as the canonical clone root, with
workstream buckets to keep contexts separated:

```text
~/github_repos/
├── external/
├── pennie/
├── personal/
├── twilio/
└── ventures/
```

`clone-repos.sh` accepts an optional bucket prefix in `repos.txt`, e.g.
`personal nmogil/dotfiles` or `ventures mogilventures/a2pcheck-app`. Herdr is
the preferred project/session cockpit (see below); start agents from the
active repo root inside a Herdr workspace.

## Herdr Agent Cockpit

Herdr (<https://herdr.dev>) is the VPS session/agent orchestration layer —
one persistent server hosting workspaces, panes, and agent sessions (Claude
Code, Codex, Hermes), with agent state detection (idle/working/blocked).
tmux remains installed as a fallback only.

`setup-linux.sh` handles the full Herdr stack:

1. **Herdr itself** — official stable installer, lands in `~/.local/bin/herdr`
2. **Integrations** — `herdr integration install claude`, `codex`, and
   `hermes` for whichever CLIs are on PATH. Herdr's installer is idempotent
   and preserves existing hooks/settings.
3. **Codex detection patch** — `server/scripts/patch-herdr-codex-detection.sh`
   adds rules to Herdr's cached Codex manifest
   (`~/.local/state/herdr/agent-detection/remote/codex.toml`) so the Codex
   "Update available" and "Hooks need review" screens classify as **blocked**
   instead of idle. Idempotent; re-run it if Herdr refreshes its remote
   manifests and the rules disappear.
4. **Hermes `herdr` skill** — `hermes skills install
   https://raw.githubusercontent.com/ogulcancelik/herdr/master/SKILL.md`,
   skipped with a log line if Hermes isn't installed or authenticated yet.

Day-to-day (aliases in `.zshrc`): `hd` attach cockpit, `hds` status, `hda`
agent list, `hdp` pane list, `hdw` workspace list.

## Hunk Diff Review

Hunk (<https://github.com/modem-dev/hunk>, npm package `hunkdiff`) is a
terminal diff viewer built for reviewing agent-written changes. Git's
`core.pager` stays **delta** — Hunk is invoked explicitly, never as the
default pager.

Workflow: keep `hunk diff` open in one terminal (or Herdr pane) watching the
working-tree diff while an agent works in another. The Claude Code skill
(symlinked to `~/.claude/skills/hunk-review` from the npm package's bundled
copy) teaches agents the session flow: `hunk session review --repo . --json`
to inspect the live review, then `hunk session comment list --repo .` and
`hunk session comment add --repo . --file <path> --new-line <n> --summary ...`
to exchange feedback on specific hunks. Agents can use
`hunk session comment apply --repo . --stdin` for JSON-batch comments. The same
skill is installed into Hermes when available.

Aliases in `.zshrc`: `hk` Hunk CLI, `hkd` diff viewer, `hkr` session review,
`hkl` comment list, `hka` JSON-batch comment apply. Config lives at `~/.config/hunk/config.toml`
(conservative defaults: auto theme/mode, line numbers, agent notes on).

## Manual Steps After Setup

1. Set terminal font to **MesloLGS NF** for proper icons
2. Add SSH key to GitHub (copied to clipboard during setup)

## Updating

To update packages after cloning on a new machine:

```bash
brew bundle --file=~/dotfiles/Brewfile
```
