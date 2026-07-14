#!/bin/bash
set -eE

# -----------------------------------------------------------------------------
# Bulk-clone repos listed in repos.txt into ~/github_repos[/<workstream>]/<repo-name>
#
# Format of repos.txt: one repo per line. Optional first field can be a workstream bucket:
#   personal owner/repo
#   ventures git@github.com:owner/repo.git
#   external https://github.com/owner/repo.git
#
# Recognized buckets come from DOTFILES_REPO_BUCKETS (default:
# "personal ventures external"); set your own in ~/.config/dotfiles/local.env.
# Without a workstream prefix, repos are cloned directly under ~/github_repos.
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
# shellcheck source=scripts/lib/local-env.sh
. "$DOTFILES_DIR/scripts/lib/local-env.sh"
dotfiles_load_config
REPOS_FILE="${1:-$DOTFILES_DIR/repos.txt}"
TARGET_DIR="${GITHUB_REPOS_DIR:-${HOME}/github_repos}"

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
for bucket in $DOTFILES_REPO_BUCKETS; do
    mkdir -p "$TARGET_DIR/$bucket"
done

CLONED=0
SKIPPED=0
FAILED=0

while IFS= read -r line || [ -n "$line" ]; do
    # Strip whitespace and skip blanks/comments
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    [[ "$line" =~ ^# ]] && continue

    # Optional workstream prefix keeps repos grouped by context.
    workstream=""
    repo_ref="$line"
    first_field="${line%%[[:space:]]*}"
    rest="${line#*[[:space:]]}"
    if [ "$rest" != "$line" ] && dotfiles_is_bucket "$first_field"; then
        workstream="$first_field"
        repo_ref="$rest"
    fi

    # Extract repo name (last path component, strip .git)
    repo_name="$(basename "$repo_ref" .git)"
    if [ -n "$workstream" ]; then
        target="$TARGET_DIR/$workstream/$repo_name"
    else
        target="$TARGET_DIR/$repo_name"
    fi

    if [ -d "$target" ]; then
        log "↺ $repo_name already exists at $target — skipping"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    log "→ Cloning $repo_ref into $target"
    if gh repo clone "$repo_ref" "$target"; then
        CLONED=$((CLONED + 1))
    else
        log "✗ Failed to clone $repo_ref"
        FAILED=$((FAILED + 1))
    fi
done < "$REPOS_FILE"

echo ""
echo "================================================================"
echo "  Done. Cloned: $CLONED  Skipped: $SKIPPED  Failed: $FAILED"
echo "  Log: $LOG_FILE"
echo "================================================================"

[ "$FAILED" -eq 0 ]
