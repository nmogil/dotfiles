#!/usr/bin/env bash
# Opt-in Mac Rex config installer. Never restarts Rex or touches agent sessions.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/config/rex"
CONFIG="${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}"
DEST="$(dirname "$CONFIG")"
MODE=dry-run
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --apply) MODE=apply ;;
    --check) MODE=check ;;
    --dry-run) MODE=dry-run ;;
    --force) FORCE=1 ;;
    -h|--help)
      echo 'Usage: ./dot rex config [--dry-run|--apply|--check] [--force]'
      echo 'Dry-run is the default. --force backs up differing files before replacing them.'
      echo 'Run rex config reload after applying. Existing unrelated files are left alone.'
      exit 0 ;;
    *) echo "setup-rex-config: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

files=(init.lua rex-image-paste/init.lua rex-image-paste/LICENSE
       rex-image-paste/UPSTREAM.md rex-image-paste/checksums.sha256
       rex-image-paste/test/e2e.lua)
target_path() {
  if [ "$1" = init.lua ]; then printf '%s\n' "$CONFIG"; else printf '%s/%s\n' "$DEST" "$1"; fi
}

# Verify the exact reviewed dependency before copying or loading any Lua.
(cd "$SOURCE/rex-image-paste" && shasum -a 256 --check checksums.sha256)
for directory in "$DEST" "$DEST/rex-image-paste" "$DEST/rex-image-paste/test"; do
  [ ! -L "$directory" ] || { echo "Refusing symlink directory: $directory" >&2; exit 1; }
done
changes=()
for relative in "${files[@]}"; do
  target="$(target_path "$relative")"
  [ ! -L "$target" ] || { echo "Refusing symlink file: $target" >&2; exit 1; }
  if [ -e "$target" ] && [ ! -f "$target" ]; then
    echo "Not a regular file: $target" >&2; exit 1
  fi
  if [ ! -f "$target" ] || ! cmp -s "$SOURCE/$relative" "$target"; then
    changes+=("$relative")
    if [ "$MODE" = apply ] && [ -f "$target" ] && [ "$FORCE" != 1 ]; then
      echo "Existing config differs: $target. Review first; --force makes backups." >&2
      exit 1
    fi
  fi
done
printf 'Rex config: %s\n' "$CONFIG"
if [ "$MODE" = dry-run ]; then
  if [ "${#changes[@]}" -gt 0 ]; then
    for relative in "${changes[@]}"; do printf 'would install %s\n' "$(target_path "$relative")"; done
  fi
  echo 'No files changed. Use --apply to install; --check to validate the installed copy.'
  exit 0
fi
[ "$(uname -s)" = Darwin ] || { echo 'Install this plugin on the Mac, not the VPS.' >&2; exit 1; }
REX="${REX_BIN:-$(command -v rex || true)}"
if [ -z "$REX" ] && [ -n "${REX_BIN_DIR:-}" ]; then REX="$REX_BIN_DIR/rex"; fi
if [ -z "$REX" ]; then
  REX="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
fi
[ -x "$REX" ] || { echo 'Cannot find Rex CLI; set REX_BIN to its absolute path.' >&2; exit 1; }
"$REX" config check "$SOURCE/init.lua"

if [ "$MODE" = check ] && [ "${#changes[@]}" -gt 0 ]; then
  printf 'Installed Rex configuration differs (%s files).\n' "${#changes[@]}" >&2
  exit 1
fi
if [ "$MODE" = apply ] && [ "${#changes[@]}" -gt 0 ]; then
  umask 077
  backup=''
  for relative in "${changes[@]}"; do
    target="$(target_path "$relative")"
    if [ -f "$target" ]; then
      if [ -z "$backup" ]; then
        mkdir -p "$HOME/.local/state/dotfiles/rex-backups"
        backup="$(mktemp -d "$HOME/.local/state/dotfiles/rex-backups/apply-XXXXXX")"
      fi
      mkdir -p "$backup/$(dirname "$relative")"
      cp -p "$target" "$backup/$relative"
    fi
    mkdir -p "$(dirname "$target")"
    cp -p "$SOURCE/$relative" "$target"
  done
  [ -z "$backup" ] || printf 'Backups: %s\n' "$backup"
fi
"$REX" config check "$CONFIG"
printf 'Rex configuration matches; %s file(s) installed.\n' "$([ "$MODE" = apply ] && echo "${#changes[@]}" || echo 0)"
echo 'Run rex config reload to apply the binding without restarting sessions.'
