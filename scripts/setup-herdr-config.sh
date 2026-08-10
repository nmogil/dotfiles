#!/usr/bin/env bash
# Apply the portable Herdr profile and Reviewr plugin preferences.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_ROOT="$ROOT/templates/herdr"
DEST_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
MODE="dry-run"

usage() {
  cat <<'EOF'
Usage: scripts/setup-herdr-config.sh [--dry-run | --apply | --check]

  --dry-run  Report config drift; write nothing (default).
  --apply    Install the portable Herdr and Reviewr configs with backups.
  --check    Exit non-zero if either config is missing or differs.

Plugin binaries and agent integrations are installed separately by setup-linux.sh.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE="dry-run" ;;
    --apply) MODE="apply" ;;
    --check) MODE="check" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "setup-herdr-config: unknown flag: $arg" >&2; usage; exit 2 ;;
  esac
done

sources=(
  "config.toml"
  "plugins/config/persiyanov.reviewr/config.toml"
)

drift=0
for relative in "${sources[@]}"; do
  source_path="$SRC_ROOT/$relative"
  dest_path="$DEST_ROOT/$relative"
  [ -f "$source_path" ] || { echo "setup-herdr-config: missing template: $source_path" >&2; exit 1; }
  if [ -f "$dest_path" ] && cmp -s "$source_path" "$dest_path"; then
    echo "  ok   $relative"
  else
    echo "  drift $relative"
    drift=1
  fi
done

case "$MODE" in
  check) exit "$drift" ;;
  dry-run)
    [ "$drift" = 0 ] || echo "Would install portable Herdr preferences."
    exit 0
    ;;
  apply)
    if [ "$drift" = 0 ]; then
      echo "Herdr portable config already matches"
      exit 0
    fi
    stamp="$(date +%Y%m%d-%H%M%S)"
    for relative in "${sources[@]}"; do
      source_path="$SRC_ROOT/$relative"
      dest_path="$DEST_ROOT/$relative"
      mkdir -p "$(dirname "$dest_path")"
      if [ -f "$dest_path" ] && ! cmp -s "$source_path" "$dest_path"; then
        cp -p "$dest_path" "$dest_path.backup.$stamp"
        echo "  backup $relative"
      fi
      cp -p "$source_path" "$dest_path"
      echo "  apply  $relative"
    done
    ;;
esac
