# Dotfiles

My personal development environment setup. One command on macOS, one command on a Linux VPS.

## Quick Start

**macOS:**
```bash
git clone https://github.com/nmogil/dotfiles.git ~/dotfiles
cd ~/dotfiles
./setup.sh
```

**Linux (Debian/Ubuntu VPS):**
```bash
git clone https://github.com/nmogil/dotfiles.git ~/dotfiles
cd ~/dotfiles
./setup-linux.sh           # dev environment (interactive: Full or Custom)
gh auth login              # then authenticate GitHub CLI
cp repos.txt.example repos.txt && $EDITOR repos.txt
./clone-repos.sh           # bulk-clone your repos into ~/code
./harden-vps.sh            # optional: Tailscale + UFW + auto-upgrades
./setup-obsidian-sync.sh   # optional: Obsidian Headless Sync
```

## What's Included

| File | Description |
|------|-------------|
| `Brewfile` | Homebrew packages and casks (macOS) |
| `.zshrc` | Zsh configuration with Oh My Zsh |
| `.p10k.zsh` | Powerlevel10k theme configuration |
| `.gitconfig` | Git settings |
| `setup.sh` | macOS installation script |
| `setup-linux.sh` | Debian/Ubuntu installation script (headless-friendly) |
| `harden-vps.sh` | Optional VPS hardening: unattended-upgrades, Tailscale, UFW |
| `setup-obsidian-sync.sh` | Optional: Obsidian Headless Sync (npm install, login, systemd user unit) |
| `clone-repos.sh` | Bulk-clone repos from `repos.txt` into `~/code` via `gh` |
| `repos.txt.example` | Template for `repos.txt` (gitignored — personal list) |

## What the Setup Script Does

1. Installs **Xcode Command Line Tools** (if needed)
2. Installs **Homebrew** (Intel & Apple Silicon compatible)
3. Installs all packages from `Brewfile`:
   - CLI tools: git, gh, node, python, flyctl, etc.
   - Apps: Arc, Obsidian, Claude Code, HiddenBar, ngrok
4. Installs **Oh My Zsh** with plugins:
   - zsh-autosuggestions
   - zsh-syntax-highlighting
   - web-search
5. Installs **Powerlevel10k** theme
6. Downloads **MesloLGS NF** fonts automatically
7. Copies all config files (with backups)
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
3. **Core CLI tools** — `fd`, `fzf`, `jq`, `ripgrep`, `zoxide`
4. **Media tools** — `ffmpeg`, `imagemagick`, `ghostscript`, `poppler`, `librsvg`, `p7zip`, `sox`
5. **MesloLGS NF fonts** — for Powerlevel10k (desktop Linux only — useless on a headless VPS)
6. **Python** — `python3`, `pip`, `venv`
7. **uv** — fast Python package/project manager from Astral
8. **GitHub CLI** — `gh` (from official apt repo)
9. **Node.js 22** — pinned via NodeSource (LTS through April 2027)
10. **Bun**
11. **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
12. **lazygit** — latest release binary
13. **flyctl**
14. **ngrok** — official apt repo
15. **Docker Compose plugin** — only if `docker` is present
16. **lazydocker** — latest release binary
17. **yazi** — only if `cargo` is present
18. **Oh My Zsh + plugins + Powerlevel10k**
19. **Config files** — copies `.zshrc`, `.p10k.zsh`, `.gitconfig` (backs up existing)
20. **Default shell** — `chsh` to zsh (prompted)
21. **SSH key** — generates `ed25519` for GitHub (prompted)

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

## Manual Steps After Setup

1. Set terminal font to **MesloLGS NF** for proper icons
2. Add SSH key to GitHub (copied to clipboard during setup)

## Updating

To update packages after cloning on a new machine:

```bash
brew bundle --file=~/dotfiles/Brewfile
```
