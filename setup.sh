#!/bin/bash
set -e

echo "=== Mac Setup Script ==="
echo ""

# Determine script directory
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/local-env.sh
. "$DOTFILES_DIR/scripts/lib/local-env.sh"
dotfiles_load_config

# Install Xcode Command Line Tools if not installed
if ! xcode-select -p &> /dev/null; then
    echo "Installing Xcode Command Line Tools..."
    xcode-select --install
    echo "Please complete the Xcode tools installation and re-run this script."
    exit 1
else
    echo "Xcode Command Line Tools already installed"
fi

# Install Homebrew if not installed
if ! command -v brew &> /dev/null; then
    echo ""
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add Homebrew to PATH for Apple Silicon Macs
    if [[ $(uname -m) == "arm64" ]]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
else
    echo "Homebrew already installed"
fi

# Install packages from Brewfile
echo ""
echo "Installing Homebrew packages..."
brew bundle --file="$DOTFILES_DIR/Brewfile"

# Install Oh My Zsh if not installed
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo ""
    echo "Installing Oh My Zsh..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
else
    echo "Oh My Zsh already installed"
fi

# Install Powerlevel10k theme
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" ]; then
    echo ""
    echo "Installing Powerlevel10k theme..."
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
        "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
else
    echo "Powerlevel10k already installed"
fi

# Install zsh-autosuggestions plugin
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" ]; then
    echo ""
    echo "Installing zsh-autosuggestions..."
    git clone https://github.com/zsh-users/zsh-autosuggestions \
        "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions"
else
    echo "zsh-autosuggestions already installed"
fi

# Install zsh-syntax-highlighting plugin
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting" ]; then
    echo ""
    echo "Installing zsh-syntax-highlighting..."
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \
        "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting"
else
    echo "zsh-syntax-highlighting already installed"
fi

# Install MesloLGS NF font for Powerlevel10k
echo ""
echo "Installing MesloLGS NF fonts for Powerlevel10k..."
FONT_DIR="$HOME/Library/Fonts"
mkdir -p "$FONT_DIR"
cd "$FONT_DIR"
for font in "MesloLGS%20NF%20Regular.ttf" "MesloLGS%20NF%20Bold.ttf" "MesloLGS%20NF%20Italic.ttf" "MesloLGS%20NF%20Bold%20Italic.ttf"; do
    decoded_font=$(echo "$font" | sed 's/%20/ /g')
    if [ ! -f "$decoded_font" ]; then
        curl -fsSLO "https://github.com/romkatv/powerlevel10k-media/raw/master/$font"
    fi
done
echo "Fonts installed"

# Backup existing configs
echo ""
echo "Backing up existing configs..."
TIMESTAMP=$(date +%Y%m%d%H%M%S)
[ -f ~/.zshrc ] && mv ~/.zshrc ~/.zshrc.backup.$TIMESTAMP || true
[ -f ~/.p10k.zsh ] && mv ~/.p10k.zsh ~/.p10k.zsh.backup.$TIMESTAMP || true
[ -f ~/.gitconfig ] && mv ~/.gitconfig ~/.gitconfig.backup.$TIMESTAMP || true

# Copy config files
echo "Installing config files..."
cp "$DOTFILES_DIR/.zshrc" ~/.zshrc
cp "$DOTFILES_DIR/.p10k.zsh" ~/.p10k.zsh

# Ghostty terminal config
GHOSTTY_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty"
mkdir -p "$GHOSTTY_DIR"
[ -f "$GHOSTTY_DIR/config" ] && mv "$GHOSTTY_DIR/config" "$GHOSTTY_DIR/config.backup.$TIMESTAMP" || true
cp "$DOTFILES_DIR/config/ghostty/config" "$GHOSTTY_DIR/config"

# Copy git config (but prompt for email/name customization)
if [ -f "$DOTFILES_DIR/.gitconfig" ]; then
    cp "$DOTFILES_DIR/.gitconfig" ~/.gitconfig
    echo ""
    if dotfiles_apply_git_identity; then
        echo "Applied git identity from ~/.config/dotfiles/local.env"
    else
        read -p "Update git user.name? (current: $(git config user.name 2>/dev/null || echo unset)) [y/N]: " update_name
        if [[ $update_name =~ ^[Yy]$ ]]; then
            read -p "Enter your name: " git_name
            git config --global user.name "$git_name"
        fi
        read -p "Update git user.email? (current: $(git config user.email 2>/dev/null || echo unset)) [y/N]: " update_email
        if [[ $update_email =~ ^[Yy]$ ]]; then
            read -p "Enter your email: " git_email
            git config --global user.email "$git_email"
        fi
    fi
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh auth setup-git
        echo "Configured GitHub CLI as the secure Git credential helper"
    fi
fi

# Generate SSH key if none exists
if [ ! -f ~/.ssh/id_ed25519 ]; then
    echo ""
    read -p "Generate SSH key for GitHub? [y/N]: " gen_ssh
    if [[ $gen_ssh =~ ^[Yy]$ ]]; then
        ssh-keygen -t ed25519 -C "$(git config user.email 2>/dev/null || echo "$(whoami)@$(hostname)")" -f ~/.ssh/id_ed25519
        eval "$(ssh-agent -s)"
        ssh-add ~/.ssh/id_ed25519
        echo ""
        echo "Your public SSH key (add to GitHub -> Settings -> SSH Keys):"
        echo "---"
        cat ~/.ssh/id_ed25519.pub
        echo "---"
        # Copy to clipboard on macOS
        cat ~/.ssh/id_ed25519.pub | pbcopy
        echo "(Copied to clipboard)"
    fi
fi

# Set macOS defaults (optional)
echo ""
read -p "Apply recommended macOS settings? [y/N]: " apply_defaults
if [[ $apply_defaults =~ ^[Yy]$ ]]; then
    echo "Applying macOS settings..."

    # Finder: show hidden files
    defaults write com.apple.finder AppleShowAllFiles -bool true

    # Finder: show all filename extensions
    defaults write NSGlobalDomain AppleShowAllExtensions -bool true

    # Finder: show path bar
    defaults write com.apple.finder ShowPathbar -bool true

    # Finder: show status bar
    defaults write com.apple.finder ShowStatusBar -bool true

    # Disable the warning when changing a file extension
    defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false

    # Avoid creating .DS_Store files on network or USB volumes
    defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
    defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true

    # Enable tap to click
    defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true

    # Faster key repeat
    defaults write NSGlobalDomain KeyRepeat -int 2
    defaults write NSGlobalDomain InitialKeyRepeat -int 15

    # Disable auto-correct
    defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false

    # Restart Finder to apply changes
    killall Finder

    echo "macOS settings applied"
fi

echo ""
echo "=== Setup Complete! ==="
echo ""
echo "Next steps:"
echo "1. Restart your terminal or run: source ~/.zshrc"
echo "2. Set your terminal font to 'MesloLGS NF' for proper icons"
echo "3. If using iTerm2/Terminal: Preferences -> Profiles -> Text -> Font"
echo ""
