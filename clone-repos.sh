#!/bin/bash
set -e

# -----------------------------------------------------------------------------
# Bulk-clone repos listed in repos.txt into ~/code/<repo-name>
#
# Format of repos.txt: one repo per line, in any of these forms:
#   owner/repo
#   git@github.com:owner/repo.git
#   https://github.com/owner/repo
#   https://github.com/owner/repo.git
#
# Lines starting with '#' and blank lines are ignored.
#
# Requires `gh` (GitHub CLI) to be installed and authenticated:
#   gh auth login
# -----------------------------------------------------------------------------

LOG_FILE="$HOME/.dotfiles-clone-repos-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

ts() { date +%H:%M:%S; }
log() { echo "  [$(ts)] $*"; }

trap 'rc=$?; echo ""; echo "✗ FAILED at line $LINENO (exit $rc)"; echo "  Full log: $LOG_FILE"; exit $rc' ERR

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_FILE="${1:-$DOTFILES_DIR/repos.txt}"
TARGET_DIR="${HOME}/code"

echo "================================================================"
echo "  Bulk-clone repos"
echo "================================================================"
echo "  Source list: $REPOS_FILE"
echo "  Target dir:  $TARGET_DIR"
echo "  Log file:    $LOG_FILE"
echo "================================================================"

if [ ! -f "$REPOS_FILE" ]; then
    echo "✗ $REPOS_FILE not found."
    echo "  Copy the example: cp repos.txt.example repos.txt"
    echo "  Then edit repos.txt to list the repos you want to clone."
    exit 1
fi

if ! command -v gh &> /dev/null; then
    echo "✗ gh (GitHub CLI) not found. Install it first: ./setup-linux.sh"
    exit 1
fi

if ! gh auth status &> /dev/null; then
    echo "✗ gh is not authenticated. Run: gh auth login"
    exit 1
fi

mkdir -p "$TARGET_DIR"

CLONED=0
SKIPPED=0
FAILED=0

while IFS= read -r line || [ -n "$line" ]; do
    # Strip whitespace and skip blanks/comments
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    [[ "$line" =~ ^# ]] && continue

    # Extract repo name (last path component, strip .git)
    repo_name="$(basename "$line" .git)"
    target="$TARGET_DIR/$repo_name"

    if [ -d "$target" ]; then
        log "↺ $repo_name already exists at $target — skipping"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    log "→ Cloning $line into $target"
    if gh repo clone "$line" "$target"; then
        CLONED=$((CLONED + 1))
    else
        log "✗ Failed to clone $line"
        FAILED=$((FAILED + 1))
    fi
done < "$REPOS_FILE"

echo ""
echo "================================================================"
echo "  Done. Cloned: $CLONED  Skipped: $SKIPPED  Failed: $FAILED"
echo "  Log: $LOG_FILE"
echo "================================================================"

[ "$FAILED" -eq 0 ]
