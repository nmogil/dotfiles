# Taps
# homebrew/bundle was deprecated and emptied upstream; `brew bundle` is built in
# now, so tapping it makes `brew bundle check` fail permanently.
tap "tw93/tap"
tap "2389-research/tap"
tap "jurplel/tap"
tap "vanducng/tap"

# CLI Tools
brew "ca-certificates"
brew "flyctl"
brew "gh"
brew "ghostscript"
brew "git"
brew "hunk"             # Review-first terminal diff viewer (macOS: brew; Linux installs npm `hunkdiff` instead)
brew "librsvg"
brew "mactop"
brew "node"
brew "poppler"
brew "python@3.11"
brew "fd"              # Simple, fast find alternative
brew "ffmpeg"          # Media processing
brew "imagemagick"     # Image manipulation
brew "lazygit"         # Terminal UI for git
brew "resvg"           # SVG rendering
brew "rtk"             # Rust Token Killer — CLI proxy for token savings
brew "sevenzip"        # Archive tool
brew "sox"             # Audio processing
brew "yazi"            # Terminal file manager
brew "zoxide"          # Smarter cd command
brew "tw93/tap/mole"   # Mole app
# Attention board for agent panes across Rex hosts (docs/rexboard.md); upstream ships Apple Silicon only.
brew "vanducng/tap/rexboard" if Hardware::CPU.arm?
# rexume (docs/rexume.md) is opt-in and not installed by `brew bundle`:
# `./dot rexume --apply` runs `brew install entwining/tap/rexume` (Apple Silicon,
# macOS 15+) after checking the Rex server and the work Pi profile.

# Optional but useful CLI tools (uncomment if wanted)
# brew "bat"          # Better cat with syntax highlighting
# brew "eza"          # Modern ls replacement
brew "fzf"            # Fuzzy finder
brew "ripgrep"        # Fast grep
brew "jq"             # JSON processor
# brew "htop"         # Better top
# brew "tldr"         # Simplified man pages
# brew "tree"         # Directory tree view

# Casks (GUI Applications)
cask "arc"
cask "claude-code"
cask "ghostty"
cask "hiddenbar"
cask "ngrok"
cask "obsidian"
cask "font-symbols-only-nerd-font"
cask "jurplel/tap/instant-space-switcher"

# Optional casks (uncomment if wanted)
# cask "visual-studio-code"
# cask "iterm2"
# cask "raycast"      # Spotlight replacement
# cask "rectangle"    # Window management
# cask "1password"
# cask "slack"
# cask "discord"
# cask "spotify"
