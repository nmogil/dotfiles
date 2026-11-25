#!/usr/bin/env bash
# setup-rexboard.sh — install/check rexboard, the attention board for agent
# panes across Rex hosts (https://github.com/vanducng/rexboard, MIT).
# See docs/rexboard.md.
#
#   macOS (Apple Silicon): Homebrew owns it (Brewfile: vanducng/tap/rexboard).
#          --apply only installs it when missing; it never upgrades,
#          reinstalls, or removes it.
#   Linux (x86_64): the release pinned in config/rexboard/release.env, with
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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="$ROOT/config/rexboard/release.env"

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

say() { printf '%s\n' "$*"; }
die() { printf 'rexboard: %s\n' "$*" >&2; exit 1; }

# Temporary paths, removed on every exit.
WORK="" STAGE=""
cleanup() {
  if [ -n "$STAGE" ]; then rm -f -- "$STAGE"; fi
  if [ -n "$WORK" ]; then rm -rf -- "$WORK"; fi
}
trap cleanup EXIT

# pin <KEY>: the value of KEY=value in release.env. Read as data, never sourced.
pin() {
  local value
  [ -f "$PINS" ] || die "missing $PINS"
  value="$(sed -n "s/^$1=//p" "$PINS" | tail -n 1)"
  [ -n "$value" ] || die "$1 is missing from $PINS"
  printf '%s' "$value"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi | cut -d' ' -f1
}

# resolve <path>: the physical path, following symlinks (no readlink -f on macOS).
resolve() {
  local p="$1" link dir
  while [ -L "$p" ]; do
    link="$(readlink "$p")"
    case "$link" in /*) p="$link" ;; *) p="$(dirname "$p")/$link" ;; esac
  done
  dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s' "$dir" "$(basename "$p")"
}

# ------------------------------------------------------------------- macOS
mac() {
  local formula cellar="" kegs="" keg real_kegs onpath resolved
  [ "$FORCE" = 0 ] || { usage >&2; exit 2; }
  formula="$(pin REXBOARD_BREW_FORMULA)"
  case "$formula" in */*/rexboard) ;; *) die "unexpected REXBOARD_BREW_FORMULA in $PINS" ;; esac
  [ "$(uname -m)" = arm64 ] || die "no macOS rexboard build for $(uname -m) (upstream ships Apple Silicon only)"

  # `brew --cellar` is a plain path query; `brew list` can initialize Homebrew's Ruby.
  if command -v brew >/dev/null 2>&1; then
    cellar="$(brew --cellar)" || { say "rexboard: brew --cellar failed; can't tell what Homebrew installed" >&2; return 1; }
    for keg in "$cellar"/rexboard/*/bin/rexboard; do
      [ -f "$keg" ] || continue
      keg="${keg%/bin/rexboard}"
      kegs="${kegs:+$kegs, }${keg##*/}"
    done
  fi
  onpath="$(command -v rexboard 2>/dev/null || true)"

  if [ -n "$kegs" ]; then
    real_kegs="$(cd -P "$cellar/rexboard" && pwd -P)"
    if [ -z "$onpath" ]; then
      say "rexboard $kegs is installed with Homebrew but isn't on PATH (brew link rexboard)" >&2
      return 1
    fi
    resolved="$(resolve "$onpath" || true)"
    case "$resolved" in
      "$real_kegs"/*) ;;
      *) say "rexboard at $onpath shadows the Homebrew one ($kegs); remove it or fix PATH" >&2; return 1 ;;
    esac
    say "rexboard $kegs installed with Homebrew ($formula); Homebrew manages its version."
    [ "$MODE" = --check ] || say "already installed; nothing to do."
    return 0
  fi
  if [ -n "$onpath" ]; then
    say "rexboard at $onpath is not from Homebrew; remove it or keep managing it by hand." >&2
    return 1
  fi
  case "$MODE" in
    --check) say "rexboard is not installed (./dot rexboard --apply)"; return 3 ;;
    --dry-run) say "would run: brew install $formula"; return 0 ;;
  esac
  command -v brew >/dev/null 2>&1 || die "Homebrew is required on macOS (./dot setup mac)"
  brew install "$formula" || die "brew install $formula failed"
  say "installed rexboard with Homebrew. Run rexboard; its first run starts rexboard serve."
}

# ------------------------------------------------------------------- Linux
# dst_state: sets STATE to missing|match|noexec|differs and DST_SHA; dies on a
# symlink or a non-regular file. Never runs the file.
dst_state() {
  DST_SHA=""
  if [ -L "$DST" ]; then
    die "$DST is a symlink; not touching it. Remove it and rerun."
  elif [ ! -e "$DST" ]; then
    STATE=missing; return 0
  elif [ ! -f "$DST" ]; then
    die "$DST is not a regular file; not touching it."
  fi
  DST_SHA="$(sha256_of "$DST")"
  if [ "$DST_SHA" != "$BINARY_SHA" ]; then STATE=differs
  elif [ -x "$DST" ]; then STATE=match
  else STATE=noexec
  fi
}

linux() {
  local arch version url archive archive_sha dir onpath member got decided before backup
  arch="$(uname -m)"
  [ "$arch" = x86_64 ] || die "no pinned rexboard build for Linux $arch (upstream publishes x86_64 only)"
  version="$(pin REXBOARD_VERSION)"
  url="$(pin REXBOARD_RELEASE_URL)"
  archive="$(pin REXBOARD_LINUX_X86_64_ARCHIVE)"
  archive_sha="$(pin REXBOARD_LINUX_X86_64_ARCHIVE_SHA256)"
  BINARY_SHA="$(pin REXBOARD_LINUX_X86_64_BINARY_SHA256)"
  printf '%s\n' "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || die "bad REXBOARD_VERSION in $PINS"
  printf '%s\n' "$archive_sha" | grep -Eqx '[0-9a-f]{64}' || die "bad REXBOARD_LINUX_X86_64_ARCHIVE_SHA256 in $PINS"
  printf '%s\n' "$BINARY_SHA" | grep -Eqx '[0-9a-f]{64}' || die "bad REXBOARD_LINUX_X86_64_BINARY_SHA256 in $PINS"
  printf '%s\n' "$archive" | grep -Eqx 'rexboard-v[0-9.]+-x86_64-unknown-linux-gnu\.tar\.gz' || die "bad archive name in $PINS"
  printf '%s\n' "$url" | grep -Eqx '(https://[A-Za-z0-9./_-]+|file:///[A-Za-z0-9./_-]+)' || die "bad REXBOARD_RELEASE_URL in $PINS"

  dir="$HOME/.local/bin"
  DST="$dir/rexboard"
  dst_state

  if [ "$MODE" = --check ]; then
    case "$STATE" in
      missing) say "rexboard is not installed at $DST (./dot rexboard --apply)"; return 3 ;;
      differs) say "rexboard at $DST differs from the pinned $version build; see docs/rexboard.md" >&2; return 1 ;;
      noexec) say "rexboard at $DST matches the pin but is not executable (./dot rexboard --apply)" >&2; return 1 ;;
    esac
    onpath="$(command -v rexboard 2>/dev/null || true)"
    if [ -n "$onpath" ] && [ "$(resolve "$onpath" || true)" != "$(resolve "$DST" || true)" ]; then
      say "rexboard at $onpath shadows $DST on PATH; remove it or fix PATH" >&2
      return 1
    fi
    say "rexboard at $DST matches the pinned $version build."
    return 0
  fi

  case "$MODE:$STATE" in
    *:match) say "rexboard $version already installed at $DST (matches the pin); nothing to do."; return 0 ;;
    --dry-run:missing) say "would install rexboard $version to $DST from $url/$archive (sha256-verified)"; return 0 ;;
    --dry-run:noexec) say "would restore the execute bit on $DST (it matches the pin)"; return 0 ;;
    --dry-run:differs)
      say "$DST differs from the pinned $version build; --apply leaves it alone (--apply --force backs it up and installs the pin)"
      return 0 ;;
    --apply:noexec)
      chmod 755 "$DST" || die "couldn't make $DST executable"
      say "restored the execute bit on $DST (matches the pinned $version build)."
      return 0 ;;
    --apply:differs)
      [ "$FORCE" = 1 ] || die "$DST differs from the pinned $version build; review it, then rerun with --apply --force (backs it up)" ;;
  esac
  decided="$STATE" before="$DST_SHA"

  # Download and verify everything before touching the destination.
  WORK="$(mktemp -d)" || die "couldn't make a temporary directory"
  curl -fsSL --proto '=https,file' --retry 2 -o "$WORK/$archive" "$url/$archive" || die "could not download $url/$archive"
  got="$(sha256_of "$WORK/$archive")"
  [ "$got" = "$archive_sha" ] || die "checksum mismatch for $archive (got $got); nothing installed"
  member="${archive%.tar.gz}/rexboard"
  mkdir "$WORK/x" || die "couldn't make a temporary directory"
  tar -xzf "$WORK/$archive" -C "$WORK/x" "$member" || die "$archive has no $member"
  [ -f "$WORK/x/$member" ] && [ ! -L "$WORK/x/$member" ] || die "$member in $archive is not a regular file"
  got="$(sha256_of "$WORK/x/$member")"
  [ "$got" = "$BINARY_SHA" ] || die "binary checksum mismatch for $member (got $got); nothing installed"

  # The destination must still be what we decided on before the download.
  dst_state
  if [ "$STATE" != "$decided" ] || [ "$DST_SHA" != "$before" ]; then
    die "$DST changed while the release downloaded; nothing installed. Rerun to review it."
  fi
  mkdir -p "$dir" || die "couldn't create $dir"
  if [ "$decided" = differs ]; then
    backup="$HOME/.local/state/dotfiles/rexboard-backups/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$backup" || die "couldn't create $backup; nothing installed"
    cp -p "$DST" "$backup/rexboard" || die "couldn't back up $DST; nothing installed"
    [ "$(sha256_of "$backup/rexboard")" = "$before" ] || die "the backup of $DST doesn't match it; nothing installed"
    say "backed up the previous $DST to $backup/rexboard"
  fi
  STAGE="$(mktemp "$dir/.rexboard.XXXXXX")" || { STAGE=""; die "couldn't write to $dir; nothing installed"; }
  cp "$WORK/x/$member" "$STAGE" || die "couldn't stage the new binary; nothing installed"
  chmod 755 "$STAGE" || die "couldn't make the staged binary executable; nothing installed"
  [ "$(sha256_of "$STAGE")" = "$BINARY_SHA" ] || die "the staged binary doesn't match the pin; nothing installed"

  if [ "$decided" = missing ]; then
    # link(2) fails if anything exists at DST, so nothing is ever overwritten.
    link "$STAGE" "$DST" 2>/dev/null || die "$DST appeared while installing; it was not overwritten"
    rm -f -- "$STAGE"
  else
    dst_state
    [ "$STATE" = differs ] && [ "$DST_SHA" = "$before" ] || die "$DST changed while installing; nothing replaced"
    # rename(2) replaces exactly DST: it never writes into a directory or through a link.
    perl -e 'rename($ARGV[0], $ARGV[1]) or die "$!\n"' "$STAGE" "$DST" || die "couldn't replace $DST"
  fi
  STAGE=""
  say "installed rexboard $version at $DST"
  case ":$PATH:" in *":$dir:"*) ;; *) say "note: $dir is not on this shell's PATH (.zshrc adds it)" ;; esac
  say "Run rexboard; its first run starts rexboard serve. A running serve keeps its old binary until it restarts."
}

case "$(uname -s)" in
  Darwin) mac ;;
  Linux) linux ;;
  *) die "unsupported OS $(uname -s)" ;;
esac
exit 0
