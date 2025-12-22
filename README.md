# Dotfiles

My personal macOS development environment setup. One command to install everything.

## Quick Start

```bash
git clone https://github.com/nmogil/dotfiles.git ~/dotfiles
cd ~/dotfiles
./setup.sh
```

## What's Included

| File | Description |
|------|-------------|
| `Brewfile` | Homebrew packages and casks |
| `.zshrc` | Zsh configuration with Oh My Zsh |
| `.p10k.zsh` | Powerlevel10k theme configuration |
| `.gitconfig` | Git settings |
| `setup.sh` | Automated installation script |

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

## Manual Steps After Setup

1. Set terminal font to **MesloLGS NF** for proper icons
2. Add SSH key to GitHub (copied to clipboard during setup)

## Updating

To update packages after cloning on a new machine:

```bash
brew bundle --file=~/dotfiles/Brewfile
```
