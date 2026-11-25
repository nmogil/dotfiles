#!/usr/bin/env bash
# Opt-in Mac Rex config installer. Never restarts Rex or touches agent sessions.
# The source and destination trees must be trusted and not modified while this
# runs (see docs/rex-image-paste.md); symlinks inside them are refused.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/config/rex"
CONFIG="${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}"
DEST="$(dirname "$CONFIG")"
CONFIG_NAME="$(basename "$CONFIG")"
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
      echo 'Also installs a private overlay (DOTFILES_REX_OVERLAY_DIR, default: rex/ beside'
      echo 'DOTFILES_PI_SCAFFOLD_DIR) when it exists; init.lua loads it if present.'
      exit 0 ;;
    *) echo "setup-rex-config: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Destination map: rels[i] (path relative to DEST) is installed from srcs[i].
# The public config goes to $CONFIG under its real (possibly custom) basename.
rels=("$CONFIG_NAME")
srcs=("$SOURCE/init.lua")
for relative in rex-image-paste/init.lua rex-image-paste/LICENSE \
    rex-image-paste/UPSTREAM.md rex-image-paste/checksums.sha256 \
    rex-image-paste/test/e2e.lua; do
  rels+=("$relative"); srcs+=("$SOURCE/$relative")
done

# Optional private overlay (e.g. the Pi session transfer, which cannot be public):
# every regular file under it is copied to the same relative path beside init.lua.
# shellcheck source=lib/local-env.sh
. "$ROOT/scripts/lib/local-env.sh"
load_local_env || true
OVERLAY="${DOTFILES_REX_OVERLAY_DIR:-}"
if [ -z "$OVERLAY" ] && [ -n "${DOTFILES_PI_SCAFFOLD_DIR:-}" ]; then
  OVERLAY="$(dirname "$DOTFILES_PI_SCAFFOLD_DIR")/rex"
fi
while [ "${#OVERLAY}" -gt 1 ] && [ "${OVERLAY%/}" != "$OVERLAY" ]; do OVERLAY="${OVERLAY%/}"; done
config_folded="$(lower "$CONFIG_NAME")"
if [ -n "$OVERLAY" ] && [ -e "$OVERLAY" ]; then
  [ -d "$OVERLAY" ] && [ ! -L "$OVERLAY" ] || { echo "Overlay is not a real directory: $OVERLAY" >&2; exit 1; }
  if [ -n "$(find "$OVERLAY" -type l -print -quit)" ]; then
    echo "Refusing symlinks inside the overlay: $OVERLAY" >&2; exit 1
  fi
  overlay_count=0
  while IFS= read -r -d '' path; do
    relative="${path#"$OVERLAY"/}"
    case "$relative" in
      README.md|*.example.json) continue ;;  # documentation/templates, not config
      /*|*..*|*[!A-Za-z0-9._/-]*) echo "Unsafe overlay path: $relative" >&2; exit 1 ;;
    esac
    folded="$(lower "$relative")"
    case "/$folded" in
      */transfer-targets.json)  # per-machine allowlist: never installed or overwritten
        echo "Overlay must not contain machine-local config: $relative" >&2; exit 1 ;;
    esac
    case "$folded" in
      init.lua|rex-image-paste|rex-image-paste/*|"$config_folded")
        echo "Overlay file would replace public config: $relative" >&2; exit 1 ;;
    esac
    rels+=("$relative"); srcs+=("$path"); overlay_count=$((overlay_count + 1))
  done < <(find "$OVERLAY" -type f -print0 | sort -z)
  printf 'Private overlay: %s (%s files)\n' "$OVERLAY" "$overlay_count"
fi

# The whole destination map must be collision-free under case folding (the Mac
# filesystem is case-insensitive): no duplicate destinations and no path that
# is a file in one entry and a directory in another.
folded_rels=()
for relative in "${rels[@]}"; do folded_rels+=("$(lower "$relative")"); done
count="${#rels[@]}"
i=0
while [ "$i" -lt "$count" ]; do
  j=$((i + 1))
  while [ "$j" -lt "$count" ]; do
    a="${folded_rels[$i]}"; b="${folded_rels[$j]}"
    if [ "$a" = "$b" ]; then
      echo "Two files map to the same destination: ${rels[$i]} and ${rels[$j]}" >&2; exit 1
    fi
    case "$b" in "$a"/*) echo "File/directory conflict: ${rels[$i]} and ${rels[$j]}" >&2; exit 1 ;; esac
    case "$a" in "$b"/*) echo "File/directory conflict: ${rels[$i]} and ${rels[$j]}" >&2; exit 1 ;; esac
    j=$((j + 1))
  done
  i=$((i + 1))
done

# Verify the exact reviewed dependency before copying or loading any Lua.
(cd "$SOURCE/rex-image-paste" && shasum -a 256 --check checksums.sha256)
# From DEST down to every installed file: no symlinked directory, and nothing
# that exists where a directory is needed may be anything but a directory.
for relative in "${rels[@]}"; do
  directory="$(dirname "$DEST/$relative")"
  while :; do
    [ ! -L "$directory" ] || { echo "Refusing symlink directory: $directory" >&2; exit 1; }
    if [ -e "$directory" ] && [ ! -d "$directory" ]; then
      echo "Not a directory: $directory (needed for $relative)" >&2; exit 1
    fi
    [ "$directory" != "$DEST" ] && [ "$directory" != "/" ] && [ "$directory" != "." ] || break
    directory="$(dirname "$directory")"
  done
done
changes=()
change_sources=()
for i in "${!rels[@]}"; do
  relative="${rels[$i]}"
  target="$DEST/$relative"
  [ ! -L "$target" ] || { echo "Refusing symlink file: $target" >&2; exit 1; }
  if [ -e "$target" ] && [ ! -f "$target" ]; then
    echo "Not a regular file: $target" >&2; exit 1
  fi
  if [ ! -f "$target" ] || ! cmp -s "${srcs[$i]}" "$target"; then
    change_sources+=("${srcs[$i]}")
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
    for relative in "${changes[@]}"; do
      target="$DEST/$relative"
      if [ -f "$target" ]; then
        printf 'would replace %s (differs; --apply needs --force, which backs it up)\n' "$target"
      else
        printf 'would install %s\n' "$target"
      fi
    done
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

if [ "$MODE" = check ]; then
  "$REX" config check "$SOURCE/init.lua"
  if [ "${#changes[@]}" -gt 0 ]; then
    printf 'Installed Rex configuration differs (%s files).\n' "${#changes[@]}" >&2
    exit 1
  fi
fi
if [ "$MODE" = apply ]; then
  # Stage the merged result (existing destination files that remain, plus every
  # planned file) and validate it before anything in DEST changes.
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/rex-config-stage.XXXXXX")"
  PARTIAL=''
  trap 'rm -rf "$STAGE"; [ -z "$PARTIAL" ] || rm -f "$PARTIAL"' EXIT
  [ ! -d "$DEST" ] || cp -RP "$DEST/." "$STAGE/"
  for i in "${!rels[@]}"; do
    mkdir -p "$(dirname "$STAGE/${rels[$i]}")"
    rm -f "$STAGE/${rels[$i]}"
    cp "${srcs[$i]}" "$STAGE/${rels[$i]}"
  done
  if ! "$REX" config check "$STAGE/$CONFIG_NAME"; then
    echo 'Staged Rex configuration failed rex config check; nothing installed.' >&2
    exit 1
  fi
fi
if [ "$MODE" = apply ] && [ "${#changes[@]}" -gt 0 ]; then
  umask 077
  backup=''
  for i in "${!changes[@]}"; do
    relative="${changes[$i]}"
    target="$DEST/$relative"
    if [ -f "$target" ]; then
      if [ -z "$backup" ]; then
        mkdir -p "$HOME/.local/state/dotfiles/rex-backups"
        backup="$(mktemp -d "$HOME/.local/state/dotfiles/rex-backups/apply-XXXXXX")"
      fi
      mkdir -p "$backup/$(dirname "$relative")"
      cp -p "$target" "$backup/$relative"
    fi
    # Replace atomically: write a temp file in the same directory, then rename
    # it over the target (never write through an existing path or hardlink).
    mkdir -p "$(dirname "$target")"
    PARTIAL="$(mktemp "$(dirname "$target")/.rex-config.XXXXXX")"
    cp -p "${change_sources[$i]}" "$PARTIAL"
    mv -f "$PARTIAL" "$target"
    PARTIAL=''
  done
  [ -z "$backup" ] || printf 'Backups: %s\n' "$backup"
fi
"$REX" config check "$CONFIG"
printf 'Rex configuration matches; %s file(s) installed.\n' "$([ "$MODE" = apply ] && echo "${#changes[@]}" || echo 0)"
echo 'Run rex config reload to apply the binding without restarting sessions.'
