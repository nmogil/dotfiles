#!/usr/bin/env bash
# Portable personal Pi settings/resources; no credential or profile mirroring.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib/local-env.sh"
dotfiles_load_config
bundle="${DOTFILES_PI_CONFIG_DIR:-}"
if [ -z "$bundle" ] && [ -n "${DOTFILES_PI_SCAFFOLD_DIR:-}" ]; then
  bundle="$(dirname "$DOTFILES_PI_SCAFFOLD_DIR")/pi-config"
fi
if [ -z "$bundle" ]; then
  echo 'pi-config: set DOTFILES_PI_CONFIG_DIR to your private baseline directory' >&2
  exit 2
fi
[ "$#" -gt 0 ] || set -- check
exec python3 "$ROOT/scripts/sync-pi-config.py" "$@" --bundle "$bundle"
