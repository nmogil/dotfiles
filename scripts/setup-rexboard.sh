#!/usr/bin/env bash
# setup-rexboard.sh — install/check rexboard, the attention board for agent
# panes across Rex hosts (https://github.com/vanducng/rexboard, MIT).
# See docs/rexboard.md.
#
#   macOS (Apple Silicon): Homebrew owns it (Brewfile: vanducng/tap/rexboard).
#          --apply only installs it when missing; it never upgrades,
#          reinstalls, or removes it.
#   Linux (x86_64): the release pinned in config/rexboard/release.pins, with
#          the archive and the binary checksum-verified, installed to
#          ~/.local/bin/rexboard.
#
# Checks are read-only: they never run rexboard and only ask Homebrew for
# `brew --cellar`. Nothing here starts, stops, or restarts `rexboard serve`, or
# runs `rexboard hooks install`.
#
# Exit codes: 0 ok; 1 problem (differs, failed, refused); 2 usage;
# 3 (--check only) rexboard is not installed.
set -euo pipefail
ROOT="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PINS="$ROOT/config/rexboard/release.pins"

usage() {
  cat <<'EOF'
usage: ./dot rexboard [--dry-run | --check | --apply [--force]]
  --dry-run       report what --apply would do (default; changes nothing)
  --check         exit 0 if installed as expected, 3 if not installed, 1 otherwise
  --apply         install rexboard if missing (Mac: Homebrew; Linux: pinned release)
  --apply --force Linux only: back up a differing ~/.local/bin/rexboard, then install the pin
EOF
}

MODE=--dry-run FORCE=0
case "$#:${1:-}:${2:-}" in
  0::) ;;
  1:--dry-run:|1:--check:|1:--apply:) MODE="$1" ;;
  2:--apply:--force) MODE=--apply FORCE=1 ;;
  1:-h:|1:--help:) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

# Shared pinned-release and Homebrew logic (data-only pins, verification,
# link/rename publishing, backups, cleanup).
# shellcheck source=scripts/lib/pinned-release.sh
. "$ROOT/scripts/lib/pinned-release.sh"
PR_NAME=rexboard PR_PINS="$PINS" PR_DOC=docs/rexboard.md
trap pr_cleanup EXIT

say() { pr_say "$@"; }
die() { pr_die "$@"; }

# ------------------------------------------------------------------- macOS
mac() {
  local formula rc=0
  [ "$FORCE" = 0 ] || { usage >&2; exit 2; }
  formula="$(pr_pin REXBOARD_BREW_FORMULA)" || exit 1
  case "$formula" in */*/rexboard) ;; *) die "unexpected REXBOARD_BREW_FORMULA in $PINS" ;; esac
  [ "$(uname -m)" = arm64 ] || die "no macOS rexboard build for $(uname -m) (upstream ships Apple Silicon only)"

  pr_brew_classify "$formula" || rc=$?
  case "$rc" in
    0) [ "$MODE" = --check ] || say "already installed; nothing to do."; return 0 ;;
    3) ;;
    *) return 1 ;;
  esac
  case "$MODE" in
    --check) say "rexboard is not installed (./dot rexboard --apply)"; return 3 ;;
    --dry-run) say "would run: brew install $formula"; return 0 ;;
  esac
  command -v brew >/dev/null 2>&1 || die "Homebrew is required on macOS (./dot setup mac)"
  brew install "$formula" || die "brew install $formula failed"
  say "installed rexboard with Homebrew. Run rexboard; its first run starts rexboard serve."
}

# ------------------------------------------------------------------- Linux
linux() {
  local arch rc=0
  arch="$(uname -m)"
  [ "$arch" = x86_64 ] || die "no pinned rexboard build for Linux $arch (upstream publishes x86_64 only)"
  pr_load_linux_pins REXBOARD 'rexboard-v[0-9.]+-x86_64-unknown-linux-gnu\.tar\.gz'

  if [ "$MODE" = --check ]; then
    pr_linux_check || rc=$?
    return "$rc"
  fi
  pr_linux_apply "$MODE" "$FORCE" "${PR_ARCHIVE%.tar.gz}/rexboard"
  [ "$PR_RESULT" = installed ] || return 0
  case ":$PATH:" in *":$PR_DIR:"*) ;; *) say "note: $PR_DIR is not on this shell's PATH (.zshrc adds it)" ;; esac
  say "Run rexboard; its first run starts rexboard serve. A running serve keeps its old binary until it restarts."
}

case "$(uname -s)" in
  Darwin) mac ;;
  Linux) linux ;;
  *) die "unsupported OS $(uname -s)" ;;
esac
exit 0
