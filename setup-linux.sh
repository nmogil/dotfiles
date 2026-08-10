#!/bin/bash
# -e: exit on error. -E: ERR trap inherited by functions (so `run` failures fire it).
set -eE

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
LOG_FILE="$HOME/.dotfiles-setup-linux-$(date +%Y%m%d-%H%M%S).log"
# Mirror everything (stdout + stderr) to the log file
exec > >(tee -a "$LOG_FILE") 2>&1

ts() { date +%H:%M:%S; }

section() {
    echo ""
    echo "================================================================"
    echo "  [$(ts)] $1"
    echo "================================================================"
}

log()  { echo "  [$(ts)] $*"; }
run()  { echo "  [$(ts)] \$ $*"; "$@"; }

# Trap any unhandled error and surface where it happened
trap 'rc=$?; echo ""; echo "✗ FAILED at line $LINENO (exit $rc)"; echo "  Full log: $LOG_FILE"; exit $rc' ERR

echo "================================================================"
echo "  Linux Setup Script (Debian/Ubuntu)"
echo "================================================================"
echo "  Started: $(date)"
echo "  Log file: $LOG_FILE"
echo "================================================================"

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/local-env.sh
. "$DOTFILES_DIR/scripts/lib/local-env.sh"
dotfiles_load_config

# -----------------------------------------------------------------------------
# Privilege detection
# -----------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    log "Running as root — no sudo needed"
else
    SUDO="sudo"
    log "Running as $(whoami) — using sudo for privileged ops"
    sudo -v
fi

if ! command -v apt-get &> /dev/null; then
    echo "✗ This script targets Debian/Ubuntu (apt). Aborting."
    exit 1
fi

# -----------------------------------------------------------------------------
# Install mode
# -----------------------------------------------------------------------------
echo ""
echo "Install mode:"
echo "  [F]ull   — install every component (default)"
echo "  [C]ustom — prompt before each component group"
echo ""
read -rp "Choose mode [F/c]: " MODE
MODE=${MODE:-F}
INTERACTIVE=false
[[ $MODE =~ ^[Cc]$ ]] && INTERACTIVE=true
log "Mode: $([ "$INTERACTIVE" = true ] && echo Custom || echo Full)"

# Returns 0 (install) or 1 (skip).
# In Full mode: always returns 0.
# In Custom mode: prompts the user with a default of Y.
should_install() {
    local desc="$1"
    if ! $INTERACTIVE; then
        return 0
    fi
    local resp
    read -rp "  Install $desc? [Y/n]: " resp
    [[ -z $resp || $resp =~ ^[Yy]$ ]]
}

# -----------------------------------------------------------------------------
# Step 1: Base tools (always installed — needed by everything below)
# -----------------------------------------------------------------------------
section "Base tools (apt update + build-essential, curl, git, zsh)"
run $SUDO apt-get update -y
run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release \
    software-properties-common \
    unzip \
    git \
    zsh

# -----------------------------------------------------------------------------
# Step 1b: Optional full system upgrade
# -----------------------------------------------------------------------------
if should_install "full system upgrade (apt upgrade -y — can take a while)"; then
    section "Full system upgrade"
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
fi

# -----------------------------------------------------------------------------
# Step 2: Core CLI tools
# -----------------------------------------------------------------------------
if should_install "core CLI tools (tmux, fd, fzf, jq, ripgrep, zoxide, micro, bat, git-delta, just, neofetch)"; then
    section "Core CLI tools"
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        tmux \
        fd-find \
        fzf \
        jq \
        ripgrep \
        zoxide \
        micro \
        bat \
        git-delta \
        just \
        neofetch

    if ! command -v fd &> /dev/null && command -v fdfind &> /dev/null; then
        mkdir -p "$HOME/.local/bin"
        ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
        log "Linked fdfind -> ~/.local/bin/fd (Debian renames the binary)"
    fi
fi

# -----------------------------------------------------------------------------
# Step 3: Media tools
# -----------------------------------------------------------------------------
if should_install "media tools (ffmpeg, imagemagick, ghostscript, poppler, librsvg, p7zip, sox)"; then
    section "Media tools"
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ffmpeg \
        ghostscript \
        imagemagick \
        librsvg2-bin \
        p7zip-full \
        poppler-utils \
        sox
fi

# -----------------------------------------------------------------------------
# Step 3b: MesloLGS NF fonts (only useful on desktop Linux — skip on headless VPS)
# -----------------------------------------------------------------------------
if should_install "MesloLGS NF fonts for Powerlevel10k (desktop Linux only — useless on headless VPS)"; then
    section "MesloLGS NF fonts"
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y fontconfig
    FONT_DIR="$HOME/.local/share/fonts"
    mkdir -p "$FONT_DIR"
    for font in "MesloLGS%20NF%20Regular.ttf" "MesloLGS%20NF%20Bold.ttf" "MesloLGS%20NF%20Italic.ttf" "MesloLGS%20NF%20Bold%20Italic.ttf"; do
        decoded_font=$(echo "$font" | sed 's/%20/ /g')
        if [ ! -f "$FONT_DIR/$decoded_font" ]; then
            log "Downloading $decoded_font"
            run wget -q "https://github.com/romkatv/powerlevel10k-media/raw/master/$font" \
                -O "$FONT_DIR/$decoded_font"
        else
            log "$decoded_font already present"
        fi
    done
    run fc-cache -f
fi

# -----------------------------------------------------------------------------
# Step 4: Python
# -----------------------------------------------------------------------------
if should_install "Python 3 + pip + venv"; then
    section "Python"
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        python3 \
        python3-pip \
        python3-venv
fi

# -----------------------------------------------------------------------------
# Step 4b: uv (fast Python package manager from Astral)
# -----------------------------------------------------------------------------
if should_install "uv (fast Python package/project manager)"; then
    section "uv"
    if command -v uv &> /dev/null; then
        log "uv already installed: $(uv --version)"
    else
        run bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
    fi
fi

# -----------------------------------------------------------------------------
# Step 5: GitHub CLI
# -----------------------------------------------------------------------------
if should_install "GitHub CLI (gh)"; then
    section "GitHub CLI"
    if command -v gh &> /dev/null; then
        log "gh already installed: $(gh --version | head -n1)"
    else
        log "Adding GitHub CLI apt repo..."
        run bash -c "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | $SUDO dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg"
        run $SUDO chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
        run bash -c "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" | $SUDO tee /etc/apt/sources.list.d/github-cli.list > /dev/null"
        run $SUDO apt-get update -y
        run $SUDO apt-get install -y gh
    fi
fi

# -----------------------------------------------------------------------------
# Step 6: Node.js (LTS via NodeSource)
# -----------------------------------------------------------------------------
if should_install "Node.js 22 (via NodeSource)"; then
    section "Node.js 22"
    if command -v node &> /dev/null; then
        log "Node already installed: $(node --version)"
    else
        # Pinned to v22 (rather than setup_lts.x) so the version doesn't drift
        # when a new LTS is cut. v22 is the current LTS through April 2027.
        # Note: no sudo `-E` flag here — it only works when $SUDO=sudo, and breaks
        # when $SUDO is empty (running as root). NodeSource doesn't need env preserved.
        run bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO bash -"
        run $SUDO apt-get install -y nodejs
        log "Node version: $(node --version)"
    fi
fi

# -----------------------------------------------------------------------------
# Step 7: Bun
# -----------------------------------------------------------------------------
if should_install "Bun"; then
    section "Bun"
    if [ -d "$HOME/.bun" ]; then
        log "Bun already installed at ~/.bun"
    else
        run bash -c "curl -fsSL https://bun.sh/install | bash"
    fi
fi

# -----------------------------------------------------------------------------
# Step 7b: Claude Code CLI (requires Node from Step 6)
# -----------------------------------------------------------------------------
if should_install "Claude Code CLI (npm install -g @anthropic-ai/claude-code)"; then
    section "Claude Code CLI"
    if ! command -v npm &> /dev/null; then
        log "npm not found — install Node.js first. Skipping Claude Code."
    elif command -v claude &> /dev/null; then
        log "Claude Code already installed: $(claude --version 2>&1 | head -n1)"
    else
        run $SUDO npm install -g @anthropic-ai/claude-code
        log "Claude Code installed. Run 'claude' to start."
    fi
fi

# -----------------------------------------------------------------------------
# Step 7c: Codex CLI (requires Node from Step 6)
# -----------------------------------------------------------------------------
if should_install "Codex CLI (npm install -g @openai/codex)"; then
    section "Codex CLI"
    if ! command -v npm &> /dev/null; then
        log "npm not found — install Node.js first. Skipping Codex."
    elif command -v codex &> /dev/null; then
        log "Codex already installed: $(codex --version 2>&1 | head -n1)"
    else
        run $SUDO npm install -g @openai/codex
        log "Codex installed. Run 'codex login' to authenticate."
    fi
fi

# -----------------------------------------------------------------------------
# Step 7d: Herdr (terminal workspace manager / agent cockpit)
# -----------------------------------------------------------------------------
if should_install "Herdr (agent session cockpit — https://herdr.dev)"; then
    section "Herdr"
    if command -v herdr &> /dev/null || [ -x "$HOME/.local/bin/herdr" ]; then
        log "Herdr already installed: $("$(command -v herdr || echo "$HOME/.local/bin/herdr")" --version 2>&1 | head -n1)"
    else
        run bash -c "curl -fsSL https://herdr.dev/install.sh | sh"
    fi
fi

# -----------------------------------------------------------------------------
# Step 7e: Herdr integrations/config + Reviewr + optional VPS Hermes config
# Runs after Claude/Codex install. Hermes is VPS-only and is touched only when
# DOTFILES_ENABLE_HERMES=1; the default workstation role never invokes it.
# -----------------------------------------------------------------------------
if should_install "Herdr integrations (pi, claude, codex; optional VPS hermes) + portable configs + Reviewr"; then
    section "Herdr integrations"
    HERDR_BIN="$(command -v herdr || true)"
    [ -z "$HERDR_BIN" ] && [ -x "$HOME/.local/bin/herdr" ] && HERDR_BIN="$HOME/.local/bin/herdr"
    if [ -z "$HERDR_BIN" ]; then
        log "herdr not found — skipping integrations (re-run after installing Herdr)"
    else
        # Herdr's installer is idempotent and preserves existing hooks/settings.
        for agent in pi claude codex; do
            if command -v "$agent" &> /dev/null; then
                run "$HERDR_BIN" integration install "$agent" \
                    || log "herdr integration install $agent failed — re-run manually later"
            else
                log "$agent not on PATH — skipping its Herdr integration"
            fi
        done
        if [ "$DOTFILES_ENABLE_HERMES" = 1 ] && command -v hermes &> /dev/null; then
            run "$HERDR_BIN" integration install hermes \
                || log "herdr integration install hermes failed — re-run manually later"
        fi
        run bash "$DOTFILES_DIR/server/scripts/patch-herdr-codex-detection.sh" \
            || log "Codex detection patch failed — re-run server/scripts/patch-herdr-codex-detection.sh later"

        run "$HERDR_BIN" plugin install persiyanov/herdr-reviewr --yes \
            || log "Reviewr plugin install failed — re-run: herdr plugin install persiyanov/herdr-reviewr --yes"
        run bash "$DOTFILES_DIR/scripts/setup-herdr-config.sh" --apply

        mkdir -p "$HOME/.local/bin"
        run install -m 0755 "$DOTFILES_DIR/bin/reviewr" "$HOME/.local/bin/reviewr"
        log "Installed reviewr wrapper (opens Reviewr beside the active agent when possible)"
    fi

    HERDR_SKILL_URL="https://raw.githubusercontent.com/ogulcancelik/herdr/master/SKILL.md"
    if [ "$DOTFILES_ENABLE_HERMES" != 1 ]; then
        log "Hermes disabled for this host (VPS-only; set DOTFILES_ENABLE_HERMES=1 on a Hermes VPS)"
    elif ! command -v hermes &> /dev/null; then
        log "hermes not installed — after installing it, run: hermes skills install $HERDR_SKILL_URL"
    elif hermes skills list 2>/dev/null | grep -qw herdr; then
        log "Hermes herdr skill already installed"
    else
        run hermes skills install --yes "$HERDR_SKILL_URL" \
            || log "Hermes herdr skill install failed (Hermes not authenticated yet?) — run manually: hermes skills install $HERDR_SKILL_URL"
    fi

    if [ "$DOTFILES_ENABLE_HERMES" = 1 ] && command -v hermes &> /dev/null; then
        run hermes config migrate \
            || log "Hermes config migration failed — run: hermes config migrate"
        run bash "$DOTFILES_DIR/scripts/setup-hermes-config.sh" --apply
    fi
fi

# -----------------------------------------------------------------------------
# Step 7f: Hunk (terminal diff review TUI for agent workflows)
# Git core.pager stays delta — Hunk is invoked explicitly, not as default pager.
# -----------------------------------------------------------------------------
if should_install "Hunk (npm install -g hunkdiff) + config + Claude/Hermes hunk-review skill"; then
    section "Hunk"
    if ! command -v npm &> /dev/null; then
        log "npm not found — install Node.js first. Skipping Hunk."
    else
        if command -v hunk &> /dev/null; then
            log "Hunk already installed: $(hunk --version 2>&1 | head -n1)"
        else
            run $SUDO npm install -g hunkdiff
        fi

        HUNK_CONF_SRC="$DOTFILES_DIR/config/hunk/config.toml"
        HUNK_CONF_DST="$HOME/.config/hunk/config.toml"
        mkdir -p "$HOME/.config/hunk"
        if [ -f "$HUNK_CONF_DST" ] && ! cmp -s "$HUNK_CONF_SRC" "$HUNK_CONF_DST"; then
            run mv "$HUNK_CONF_DST" "$HUNK_CONF_DST.backup.$(date +%Y%m%d%H%M%S)"
        fi
        run cp "$HUNK_CONF_SRC" "$HUNK_CONF_DST"

        # Claude Code skill — symlink the copy bundled inside the installed package
        HUNK_SKILL_DIR="$(dirname "$(hunk skill path)")"
        HUNK_SKILL_LINK="$HOME/.claude/skills/hunk-review"
        if [ ! -d "$HUNK_SKILL_DIR" ]; then
            log "Bundled hunk-review skill not found at $HUNK_SKILL_DIR — skipping Claude skill link"
        elif [ -e "$HUNK_SKILL_LINK" ] && [ ! -L "$HUNK_SKILL_LINK" ]; then
            log "$HUNK_SKILL_LINK exists and is not a symlink — leaving it in place"
        else
            mkdir -p "$HOME/.claude/skills"
            run ln -sfn "$HUNK_SKILL_DIR" "$HUNK_SKILL_LINK"
        fi

        # Hermes skill — non-fatal, mirrors the Herdr skill pattern above
        HUNK_SKILL_URL="https://raw.githubusercontent.com/modem-dev/hunk/main/skills/hunk-review/SKILL.md"
        if [ "$DOTFILES_ENABLE_HERMES" != 1 ]; then
            log "Hermes hunk-review skill skipped (Hermes disabled for this host)"
        elif ! command -v hermes &> /dev/null; then
            log "hermes not installed — after installing it, run: hermes skills install $HUNK_SKILL_URL"
        elif hermes skills list 2>/dev/null | grep -qw hunk-review; then
            log "Hermes hunk-review skill already installed"
        else
            run hermes skills install --yes "$HUNK_SKILL_URL" \
                || log "Hermes hunk-review skill install failed (Hermes not authenticated yet?) — run manually: hermes skills install $HUNK_SKILL_URL"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Step 8: lazygit
# -----------------------------------------------------------------------------
if should_install "lazygit"; then
    section "lazygit"
    if command -v lazygit &> /dev/null; then
        log "lazygit already installed: $(lazygit --version | head -n1)"
    else
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) LG_ARCH="x86_64" ;;
            aarch64|arm64) LG_ARCH="arm64" ;;
            *) log "Unsupported arch: $ARCH — skipping"; LG_ARCH="" ;;
        esac
        if [ -n "$LG_ARCH" ]; then
            LAZYGIT_VERSION=$(curl -fsSL "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" \
                | grep -Po '"tag_name": *"v\K[^"]*')
            log "Installing lazygit $LAZYGIT_VERSION ($LG_ARCH)"
            TMP=$(mktemp -d)
            run curl -fsSL -o "$TMP/lazygit.tar.gz" \
                "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_${LG_ARCH}.tar.gz"
            run tar -xzf "$TMP/lazygit.tar.gz" -C "$TMP" lazygit
            run $SUDO install "$TMP/lazygit" /usr/local/bin/
            rm -rf "$TMP"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Step 9: flyctl
# -----------------------------------------------------------------------------
if should_install "flyctl"; then
    section "flyctl"
    if command -v flyctl &> /dev/null || command -v fly &> /dev/null; then
        log "flyctl already installed"
    else
        run bash -c "curl -fsSL https://fly.io/install.sh | sh"
    fi
fi

# -----------------------------------------------------------------------------
# Step 9b: ngrok (apt repo)
# -----------------------------------------------------------------------------
if should_install "ngrok (tunnels localhost to a public URL)"; then
    section "ngrok"
    if command -v ngrok &> /dev/null; then
        log "ngrok already installed: $(ngrok version 2>&1 | head -n1)"
    else
        log "Adding ngrok apt repo..."
        run bash -c "curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc | $SUDO tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null"
        run bash -c "echo 'deb https://ngrok-agent.s3.amazonaws.com bookworm main' | $SUDO tee /etc/apt/sources.list.d/ngrok.list"
        run $SUDO apt-get update -y
        run $SUDO apt-get install -y ngrok
        log "After install, run: ngrok config add-authtoken <your-token>"
    fi
fi

# -----------------------------------------------------------------------------
# Step 10: Docker Compose plugin (only if Docker is present)
# -----------------------------------------------------------------------------
if should_install "Docker Compose plugin (only if docker is installed)"; then
    section "Docker Compose plugin"
    if command -v docker &> /dev/null; then
        if docker compose version &> /dev/null; then
            log "docker compose plugin already installed: $(docker compose version)"
        else
            run $SUDO apt-get install -y docker-compose-plugin
        fi
    else
        log "docker not detected — skipping (install Docker first if you need it)"
    fi
fi

# -----------------------------------------------------------------------------
# Step 11: lazydocker
# -----------------------------------------------------------------------------
if should_install "lazydocker"; then
    section "lazydocker"
    if command -v lazydocker &> /dev/null; then
        log "lazydocker already installed"
    else
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) LD_ARCH="x86_64" ;;
            aarch64|arm64) LD_ARCH="arm64" ;;
            *) log "Unsupported arch: $ARCH — skipping"; LD_ARCH="" ;;
        esac
        if [ -n "$LD_ARCH" ]; then
            LAZYDOCKER_VERSION=$(curl -fsSL "https://api.github.com/repos/jesseduffield/lazydocker/releases/latest" \
                | grep -Po '"tag_name": *"v\K[^"]*')
            log "Installing lazydocker $LAZYDOCKER_VERSION ($LD_ARCH)"
            TMP=$(mktemp -d)
            run curl -fsSL -o "$TMP/lazydocker.tar.gz" \
                "https://github.com/jesseduffield/lazydocker/releases/latest/download/lazydocker_${LAZYDOCKER_VERSION}_Linux_${LD_ARCH}.tar.gz"
            run tar -xzf "$TMP/lazydocker.tar.gz" -C "$TMP" lazydocker
            run $SUDO install "$TMP/lazydocker" /usr/local/bin/
            rm -rf "$TMP"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Step 12: yazi (cargo only — skipped if cargo missing)
# -----------------------------------------------------------------------------
if should_install "yazi (terminal file manager — requires cargo)"; then
    section "yazi"
    if command -v yazi &> /dev/null; then
        log "yazi already installed"
    elif command -v cargo &> /dev/null; then
        run cargo install --locked yazi-fm yazi-cli
    else
        log "cargo not found — skipping yazi (install Rust toolchain first)"
    fi
fi

# -----------------------------------------------------------------------------
# Step 13: Oh My Zsh + plugins + Powerlevel10k
# -----------------------------------------------------------------------------
if should_install "Oh My Zsh + zsh plugins + Powerlevel10k theme"; then
    section "Oh My Zsh + plugins + Powerlevel10k"

    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        run sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    else
        log "Oh My Zsh already installed"
    fi

    P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
    if [ ! -d "$P10K_DIR" ]; then
        run git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
    else
        log "Powerlevel10k already installed"
    fi

    AUTOSUG_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions"
    if [ ! -d "$AUTOSUG_DIR" ]; then
        run git clone https://github.com/zsh-users/zsh-autosuggestions "$AUTOSUG_DIR"
    else
        log "zsh-autosuggestions already installed"
    fi

    SYNTAX_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting"
    if [ ! -d "$SYNTAX_DIR" ]; then
        run git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$SYNTAX_DIR"
    else
        log "zsh-syntax-highlighting already installed"
    fi
fi

# -----------------------------------------------------------------------------
# Step 14: Copy dotfiles (.zshrc, .p10k.zsh, .gitconfig, .tmux.conf)
# -----------------------------------------------------------------------------
if should_install "config files (.zshrc, .p10k.zsh, .gitconfig, .tmux.conf — backs up existing)"; then
    section "Config files"
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    [ -f ~/.zshrc ]     && run mv ~/.zshrc     ~/.zshrc.backup.$TIMESTAMP
    [ -f ~/.p10k.zsh ]  && run mv ~/.p10k.zsh  ~/.p10k.zsh.backup.$TIMESTAMP
    [ -f ~/.gitconfig ] && run mv ~/.gitconfig ~/.gitconfig.backup.$TIMESTAMP
    [ -f ~/.tmux.conf ] && run mv ~/.tmux.conf ~/.tmux.conf.backup.$TIMESTAMP

    run cp "$DOTFILES_DIR/.zshrc"    ~/.zshrc
    run cp "$DOTFILES_DIR/.p10k.zsh" ~/.p10k.zsh
    [ -f "$DOTFILES_DIR/.tmux.conf" ] && run cp "$DOTFILES_DIR/.tmux.conf" ~/.tmux.conf

    if [ -f "$DOTFILES_DIR/.gitconfig" ]; then
        run cp "$DOTFILES_DIR/.gitconfig" ~/.gitconfig
        echo ""
        if dotfiles_apply_git_identity; then
            log "Applied git identity from ~/.config/dotfiles/local.env"
        else
            read -rp "Update git user.name? (current: $(git config user.name 2>/dev/null || echo 'unset')) [y/N]: " update_name
            if [[ $update_name =~ ^[Yy]$ ]]; then
                read -rp "Enter your name: " git_name
                run git config --global user.name "$git_name"
            fi
            read -rp "Update git user.email? (current: $(git config user.email 2>/dev/null || echo 'unset')) [y/N]: " update_email
            if [[ $update_email =~ ^[Yy]$ ]]; then
                read -rp "Enter your email: " git_email
                run git config --global user.email "$git_email"
            fi
        fi
        if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
            run gh auth setup-git
            log "Configured GitHub CLI as the secure Git credential helper"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Step 15: chsh to zsh
# -----------------------------------------------------------------------------
if [ "$SHELL" != "$(command -v zsh)" ]; then
    section "Default shell"
    read -rp "Set zsh as your default shell? [y/N]: " set_zsh
    if [[ $set_zsh =~ ^[Yy]$ ]]; then
        run chsh -s "$(command -v zsh)" || log "chsh failed — run it manually later"
    fi
fi

# -----------------------------------------------------------------------------
# Step 16: SSH key
# -----------------------------------------------------------------------------
if [ ! -f ~/.ssh/id_ed25519 ]; then
    section "SSH key"
    read -rp "Generate ed25519 SSH key for GitHub? [y/N]: " gen_ssh
    if [[ $gen_ssh =~ ^[Yy]$ ]]; then
        run ssh-keygen -t ed25519 -C "$(git config user.email 2>/dev/null || echo "$(whoami)@$(hostname)")" -f ~/.ssh/id_ed25519
        eval "$(ssh-agent -s)"
        run ssh-add ~/.ssh/id_ed25519
        echo ""
        echo "Public key (add to GitHub -> Settings -> SSH Keys):"
        echo "---"
        cat ~/.ssh/id_ed25519.pub
        echo "---"
    fi
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
section "Setup Complete"
log "Finished: $(date)"
log "Full log saved to: $LOG_FILE"
echo ""
echo "Next steps:"
echo "  1. Start a new shell: exec zsh   (or log out and back in)"
echo "  2. Authenticate GitHub CLI: gh auth login"
echo "  3. Bulk-clone your repos: cp repos.txt.example repos.txt && ./clone-repos.sh"
echo "  4. If exposed to public internet, harden the box: ./harden-vps.sh"
echo "  5. Launch the agent cockpit: herdr   (tmux remains as fallback)"
echo "  6. Set local terminal font to 'MesloLGS NF' for Powerlevel10k icons"
echo ""
