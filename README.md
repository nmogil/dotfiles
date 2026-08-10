# Dotfiles

A personal development environment setup: one command on macOS, one command on a
Linux VPS. Published as a reference for how one machine is wired up — not a
turnkey product. **Read the scripts before you run them**; they install
packages, copy config into your `$HOME`, and can harden a VPS. Fork and adapt
rather than running blind. See [Licensing & provenance](#licensing--provenance)
before reusing parts of it.

Machine- and person-specific values (git identity, workstream repo buckets,
private endpoints) are intentionally **not** tracked here — see
[Local configuration](#local-configuration).

## The short version

If you're here because you asked about my setup, this is the core of it:

- **Terminal**: [Ghostty](https://ghostty.org) + zsh + Oh My Zsh +
  [Powerlevel10k](https://github.com/romkatv/powerlevel10k)
  (`config/ghostty/config`, `.zshrc`, `.p10k.zsh`)
- **Git**: [delta](https://github.com/dandavison/delta) as pager,
  `zdiff3` conflicts, identity kept out of the repo, `gh` as the credential
  helper — no plaintext credential store (`.gitconfig`)
- **Agents**: Claude Code, Codex, and [Pi](https://github.com/mariozechner/pi),
  with [Herdr](https://herdr.dev) as the session cockpit and
  [Hunk](https://hunk.dev) for reviewing agent diffs
- **Repo hygiene**: everything clones into `~/github_repos/<workstream>/`
  buckets to keep contexts separated (`./dot repos clone`)
- **One command**: `./dot setup mac` (or `./dot setup linux` for a VPS), then
  `./dot doctor` to verify

Everything below is the detail.

## Quick Start

`./dot` is the control surface — a thin wrapper over the scripts below. Run
`./dot help` for all commands and `./dot doctor` for a read-only health check.
The direct script commands still work if you prefer them. The canonical repo is
`https://github.com/nmogil/dotfiles.git`; swap in your own fork's URL if you
forked it.

**macOS:**
```bash
git clone https://github.com/nmogil/dotfiles.git ~/dotfiles
cd ~/dotfiles
mkdir -p ~/.config/dotfiles                                        # optional local config
cp config/dotfiles/local.env.example ~/.config/dotfiles/local.env  # optional; then edit
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

See [`AGENTS.md`](AGENTS.md) for where to edit things and safety rules, and
[Local configuration](#local-configuration) for machine-specific values.

## Local configuration

Portable defaults live in the tracked scripts; anything personal or
machine-specific stays in an optional file **outside** this repo so it is never
committed:

```bash
mkdir -p ~/.config/dotfiles
cp config/dotfiles/local.env.example ~/.config/dotfiles/local.env
$EDITOR ~/.config/dotfiles/local.env
```

Everything works without it — the scripts fall back to generic defaults. When
present, `setup`, `clone-repos`, `doctor`, and `./dot pi doctor` source it.
Note it is read by these repo scripts, **not** automatically by unrelated Pi
processes. Documented keys (see
[`config/dotfiles/local.env.example`](config/dotfiles/local.env.example)):

| Key | Effect | Default |
|-----|--------|---------|
| `DOTFILES_GIT_NAME` / `DOTFILES_GIT_EMAIL` | Git identity, written to `~/.config/git/local.gitconfig` (included by `.gitconfig`) instead of prompting | prompt / unset |
| `DOTFILES_REPO_BUCKETS` | Workstream bucket dirs + recognized `repos.txt` prefixes | `personal ventures external` |
| `GITHUB_REPOS_DIR` | Clone root | `~/github_repos` |
| `PI_MEMORY_COMPILER_DIR` | Consumed by the Pi memory-compiler extension **only when exported into the Pi process environment** (e.g. your shell rc) or set in `~/.pi/agent/memory-compiler.json`; putting it in `local.env` alone does not reach Pi | `~/github_repos/personal/claude-memory-compiler` |
| `DOTFILES_PI_BLOCKLIST` | Extra private-string regexes `./dot pi doctor` rejects in the Pi scaffold | `~/.config/dotfiles/pi-scaffold-blocklist.txt` |

**Shell-level machine locals.** `local.env` is read by the repo's scripts, not by
your interactive shell. For per-machine *shell* config — private hostnames,
session names, one-off aliases — the tracked `.zshrc` sources `~/.zshrc.local`
at the end if it exists. That file is outside the repo and never committed.

**Migrating from an earlier personal checkout.** The tracked `.gitconfig` no
longer carries an identity. Recreate yours locally (values below are
placeholders — use your own):

```bash
mkdir -p ~/.config/dotfiles
cat > ~/.config/dotfiles/local.env <<'EOF'
DOTFILES_GIT_NAME="Your Name"
DOTFILES_GIT_EMAIL="you@example.com"
DOTFILES_REPO_BUCKETS="personal ventures external"
EOF
# or, without local.env:
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

The setup scripts also run `gh auth setup-git` when GitHub CLI is already
authenticated, rather than installing Git's plaintext `credential.helper=store`.

Add any private workstream codenames to `DOTFILES_REPO_BUCKETS`, and keep the
private-endpoint patterns you want `./dot pi doctor` to reject in
`~/.config/dotfiles/pi-scaffold-blocklist.txt` (one regex per line).

## What's Included

| File | Description |
|------|-------------|
| `dot` | Control surface — thin wrapper over the setup scripts (`./dot help`) |
| `scripts/doctor.sh` | Read-only environment health check (`./dot doctor`) |
| `AGENTS.md` | Where to edit things + safety rules for agents/humans |
| `packages/` | Package manifests split by role + `./dot packages check` |
| `docs/chezmoi-plan.md` | Planned (not yet applied) chezmoi migration |
| `scripts/setup-pi-agent.sh` | Opt-in Pi workspace installer (`./dot pi ...`, `docs/pi-agent-setup.md`); the scaffold itself lives outside this repo |
| `scripts/setup-claude-memory-hooks.sh` | Opt-in Claude Code capture hooks for the memory compiler (`./dot claude hooks`, `docs/claude-memory-compiler.md`) |
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
| `config/dotfiles/local.env.example` | Template for machine-local overrides (copy to `~/.config/dotfiles/local.env`) |
| `scripts/lib/local-env.sh` | Loader for the local config layer + portable defaults |
| `scripts/tests/local-env.test.sh` | Focused test for override loading and defaults |
| `templates/herdr/`, `scripts/setup-herdr-config.sh` | Portable Herdr/Reviewr preferences and drift-safe installer |
| `templates/hermes/config.portable.yaml`, `scripts/setup-hermes-config.sh` | Credential-free Hermes preferences, deep-merged without touching local secrets/state |
| `docs/agent-config-sync.md` | Cross-machine Herdr, Pi, and Hermes bootstrap and safety boundary |
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
14. **Herdr integrations/config** — `herdr integration install pi|claude|codex|hermes` (skips agents not on PATH), Reviewr, the Codex detection patch, portable Herdr preferences, the Hermes `herdr` skill, and portable Hermes preferences when Hermes is present
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

An opt-in [Pi coding agent](https://github.com/mariozechner/pi) workspace. It is
**not** applied by the setup scripts — you install it deliberately. The scaffold
content is **not tracked in this repo**: it was adapted from
[dmmulroy/.dotfiles](https://github.com/dmmulroy/.dotfiles), which grants no
license, so it lives in a private companion repo until that is resolved. Point
`DOTFILES_PI_SCAFFOLD_DIR` (in `~/.config/dotfiles/local.env`) at your own
scaffold checkout; a fork-local `templates/pi/` works as a fallback.

```bash
./dot pi doctor               # read-only checks
./dot pi scaffold --dry-run   # preview copy into ~/.pi (writes nothing)
./dot pi scaffold --apply     # copy scaffold (skips existing; --force backs up)
./dot pi profiles --apply     # prepare separate personal/work profiles
./dot pi subagents --dry-run  # preview pinned Pi subagent package setup
./dot pi subagents --apply    # install pinned @ogulcancelik/pi-codex-subagents
./dot pi install              # install pinned npm Pi; migrates Vite+ Pi after confirmation
./dot herdr config --apply    # install exact Herdr + Reviewr preferences
./dot hermes config --apply   # deep-merge portable Hermes preferences
```

Live config stays gitignored. Pi works
directly by default and delegates only under the reviewed routing policy. The
profile setup keeps credentials/sessions separate, shares reviewed resources,
and installs a Hermes rule that requires explicit profile selection for fresh
Pi workers. Set `DOTFILES_PI_WORK_PROFILE_SLUG` in the gitignored local config
to name the second profile without publishing the workstream name. In-process
Pi Subagents inherit the parent profile; Hermes-native
`delegate_task` children inherit Hermes provider credentials and are unrelated
to Pi auth. See [`docs/pi-agent-setup.md`](docs/pi-agent-setup.md) for
installation and operations.

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
├── personal/
└── ventures/
```

Buckets default to `personal ventures external` and are configurable via
`DOTFILES_REPO_BUCKETS` in `~/.config/dotfiles/local.env` (add codenamed
employer/client buckets there — they stay out of the repo). `clone-repos.sh`
accepts an optional bucket prefix in `repos.txt`, e.g. `personal owner/dotfiles`
or `ventures owner/some-app`. Herdr is the preferred project/session cockpit
(see below); start agents from the active repo root inside a Herdr workspace.

## Herdr Agent Cockpit

Herdr (<https://herdr.dev>) is the VPS session/agent orchestration layer —
one persistent server hosting workspaces, panes, and agent sessions (Pi, Claude
Code, Codex, Hermes), with agent state detection (idle/working/blocked).
tmux remains installed as a fallback only.

`setup-linux.sh` handles the full Herdr stack:

1. **Herdr itself** — official stable installer, lands in `~/.local/bin/herdr`
2. **Integrations** — `herdr integration install pi`, `claude`, `codex`, and
   `hermes` for whichever CLIs are on PATH. Herdr's installer is idempotent
   and preserves existing hooks/settings.
3. **Codex detection patch** — `server/scripts/patch-herdr-codex-detection.sh`
   adds rules to Herdr's cached Codex manifest
   (`~/.local/state/herdr/agent-detection/remote/codex.toml`) so the Codex
   "Update available" and "Hooks need review" screens classify as **blocked**
   instead of idle. Idempotent; re-run it if Herdr refreshes its remote
   manifests and the rules disappear.
4. **Reviewr and portable config** — installs `persiyanov/herdr-reviewr`, copies
   the Vesper/keybinding profile from `templates/herdr/`, and deep-merges the
   allowlisted Hermes preferences without copying secrets or runtime state.
5. **Hermes `herdr` skill** — `hermes skills install
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

## Licensing & provenance

MIT — see [`LICENSE`](LICENSE). The material that previously blocked a license
(a Pi scaffold adapted from an unlicensed upstream) has been moved out of this
repository; what remains is original work plus conventional/generated config
whose upstreams (Oh My Zsh, Powerlevel10k) are MIT. Two caveats, detailed in
[`docs/licensing.md`](docs/licensing.md):

- Generated/derived config (`.p10k.zsh`, `.zshrc`) carries its upstream's MIT
  terms, not a fresh claim of authorship.
- Third-party software the scripts install retains its own licenses; this repo
  only automates fetching it.
- The removed scaffold still exists in this repository's **git history**; the
  license applies to the current tree, not to historical unlicensed material.
