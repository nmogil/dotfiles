#!/usr/bin/env bash
# setup-rexboard.sh — install/check rexboard, the attention board for agent
# panes across Rex hosts (https://github.com/vanducng/rexboard, MIT).
# See docs/rexboard.md.
#
#   macOS: Homebrew owns it (Brewfile: vanducng/tap/rexboard). --apply only
#          installs it when missing; it never upgrades, reinstalls, or removes.
#   Linux: the release pinned in config/rexboard/release.env, checksum-verified
#          (archive and binary), installed to ~/.local/bin/rexboard.
#
# Never starts, stops, or restarts `rexboard serve`, and never runs
# `rexboard hooks install`.
#
# Exit codes: 0 ok; 1 problem (differs, failed, refused); 2 usage;
# 3 (--check only) rexboard is not installed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="$ROOT/config/rexboard/release.env"

usage() {
  cat <<'EOF'
usage: ./dot rexboard [--dry-run | --check | --apply [--force]]
  --dry-run       report what --apply would do (default; changes nothing)
  --check         exit 0 if installed as expected, 3 if not installed, 1 otherwise
  --apply         install rexboard if missing (Mac: Homebrew; Linux: pinned release)
  --apply --force Linux: back up a differing ~/.local/bin/rexboard, then install the pin
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

say() { printf '%s\n' "$*"; }
die() { printf 'rexboard: %s\n' "$*" >&2; exit 1; }

# pin <KEY>: the value of KEY=value in release.env. Read as data, never sourced.
pin() {
  local value
  [ -f "$PINS" ] || die "missing $PINS"
  value="$(sed -n "s/^$1=//p" "$PINS" | tail -n 1)"
  [ -n "$value" ] || die "$1 is missing from $PINS"
  printf '%s' "$value"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# ------------------------------------------------------------------- macOS
mac() {
  local formula version other
  formula="$(pin REXBOARD_BREW_FORMULA)"
  case "$formula" in */*/rexboard) ;; *) die "unexpected REXBOARD_BREW_FORMULA in $PINS" ;; esac
  version=""
  if command -v brew >/dev/null 2>&1; then
    version="$(brew list --versions rexboard 2>/dev/null | sed -n 's/^rexboard //p' | head -n 1 || true)"
  fi
  if [ -n "$version" ]; then
    say "rexboard $version installed with Homebrew ($formula); Homebrew manages its version."
    [ "$MODE" = --check ] || say "already installed; nothing to do."
    return 0
  fi
  other="$(command -v rexboard 2>/dev/null || true)"
  if [ -n "$other" ]; then
    say "rexboard at $other is not from Homebrew; remove it or keep managing it by hand." >&2
    return 1
  fi
  case "$MODE" in
    --check) say "rexboard is not installed (./dot rexboard --apply)"; return 3 ;;
    --dry-run) say "would run: brew install $formula"; return 0 ;;
  esac
  command -v brew >/dev/null 2>&1 || die "Homebrew is required on macOS (./dot setup mac)"
  brew install "$formula"
  say "installed rexboard with Homebrew. Run rexboard; its first run starts rexboard serve."
}

# ------------------------------------------------------------------- Linux
linux() {
  local arch version url archive archive_sha binary_sha dst dir current tmp member got backup stage
  arch="$(uname -m)"
  [ "$arch" = x86_64 ] || die "no pinned rexboard build for Linux $arch (upstream publishes x86_64 only)"
  version="$(pin REXBOARD_VERSION)"
  url="$(pin REXBOARD_RELEASE_URL)"
  archive="$(pin REXBOARD_LINUX_X86_64_ARCHIVE)"
  archive_sha="$(pin REXBOARD_LINUX_X86_64_ARCHIVE_SHA256)"
  binary_sha="$(pin REXBOARD_LINUX_X86_64_BINARY_SHA256)"
  printf '%s\n' "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || die "bad REXBOARD_VERSION in $PINS"
  printf '%s\n' "$archive_sha" | grep -Eqx '[0-9a-f]{64}' || die "bad REXBOARD_LINUX_X86_64_ARCHIVE_SHA256 in $PINS"
  printf '%s\n' "$binary_sha" | grep -Eqx '[0-9a-f]{64}' || die "bad REXBOARD_LINUX_X86_64_BINARY_SHA256 in $PINS"
  printf '%s\n' "$archive" | grep -Eqx 'rexboard-v[0-9.]+-x86_64-unknown-linux-gnu\.tar\.gz' || die "bad archive name in $PINS"
  printf '%s\n' "$url" | grep -Eqx '(https://[A-Za-z0-9./_-]+|file:///[A-Za-z0-9./_-]+)' || die "bad REXBOARD_RELEASE_URL in $PINS"

  dir="$HOME/.local/bin"
  dst="$dir/rexboard"
  current=missing
  if [ -L "$dst" ]; then
    die "$dst is a symlink; not touching it. Remove it and rerun."
  elif [ -e "$dst" ]; then
    [ -f "$dst" ] || die "$dst is not a regular file; not touching it."
    if [ "$(sha256_of "$dst")" = "$binary_sha" ]; then current=match; else current=differs; fi
  fi

  case "$MODE:$current" in
    --check:match) say "rexboard at $dst matches the pinned $version build."; return 0 ;;
    --check:missing) say "rexboard is not installed at $dst (./dot rexboard --apply)"; return 3 ;;
    --check:differs)
      say "rexboard at $dst differs from the pinned $version build ($("$dst" --version 2>/dev/null | head -n 1 || echo "unknown version")); see docs/rexboard.md" >&2
      return 1 ;;
    *:match) say "rexboard $version already installed at $dst (matches the pin); nothing to do."; return 0 ;;
    --dry-run:missing) say "would install rexboard $version to $dst from $url/$archive (sha256-verified)"; return 0 ;;
    --dry-run:differs)
      say "$dst differs from the pinned $version build; --apply leaves it alone (--apply --force backs it up and installs the pin)"
      return 0 ;;
    --apply:differs)
      [ "$FORCE" = 1 ] || die "$dst differs from the pinned $version build; review it, then rerun with --apply --force (backs it up)"
      ;;
  esac

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: tmp is local
  trap "rm -rf '$tmp'" EXIT
  curl -fsSL --proto '=https,file' --retry 2 -o "$tmp/$archive" "$url/$archive" || die "could not download $url/$archive"
  got="$(sha256_of "$tmp/$archive")"
  [ "$got" = "$archive_sha" ] || die "checksum mismatch for $archive (got $got); nothing installed"
  member="${archive%.tar.gz}/rexboard"
  mkdir "$tmp/x"
  tar -xzf "$tmp/$archive" -C "$tmp/x" "$member" || die "$archive has no $member"
  [ -f "$tmp/x/$member" ] && [ ! -L "$tmp/x/$member" ] || die "$member in $archive is not a regular file"
  got="$(sha256_of "$tmp/x/$member")"
  [ "$got" = "$binary_sha" ] || die "binary checksum mismatch for $member (got $got); nothing installed"

  mkdir -p "$dir"
  if [ "$current" = differs ]; then
    backup="$HOME/.local/state/dotfiles/rexboard-backups/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$backup"
    cp -p "$dst" "$backup/rexboard"
    say "backed up the previous $dst to $backup/rexboard"
  fi
  # Write beside the destination, then rename: no partial file, and a hard link
  # to the old binary is never written through. A running `rexboard serve`
  # keeps the old binary until it restarts.
  stage="$(mktemp "$dir/.rexboard.XXXXXX")"
  cp "$tmp/x/$member" "$stage"
  chmod 755 "$stage"
  mv -f "$stage" "$dst"
  say "installed rexboard $version at $dst"
  case ":$PATH:" in *":$dir:"*) ;; *) say "note: $dir is not on this shell's PATH (.zshrc adds it)" ;; esac
  say "Run rexboard; its first run starts rexboard serve. A running serve keeps its old binary until it restarts."
}

rc=0
case "$(uname -s)" in
  Darwin) mac || rc=$? ;;
  Linux) linux || rc=$? ;;
  *) die "unsupported OS $(uname -s)" ;;
esac
exit "$rc"
