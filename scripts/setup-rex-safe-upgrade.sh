#!/usr/bin/env bash
# Install rex-safe-upgrade and the Pi pane recorder it depends on.
# See docs/rex-safe-upgrade.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
marker='Managed by dotfiles:'

tool_src="$ROOT/scripts/rex-safe-upgrade.py"
tool_dst="$HOME/.local/bin/rex-safe-upgrade"
ext_src="$ROOT/templates/pi-rex/rex-pane-session.ts"
ext_dst="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/extensions/rex-pane-session.ts"

# Replace only files we installed (they carry the marker) or missing ones.
install_one() {
  local src="$1" dst="$2" mode="$3"
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst" && ! grep -q "$marker" "$dst"; then
    printf '%s\n' "Refusing to replace $dst: it was not installed by dotfiles. Review it, remove it, and rerun." >&2
    return 1
  fi
  mkdir -p "$(dirname "$dst")"
  install -m "$mode" "$src" "$dst"
  printf 'Installed %s\n' "$dst"
}

case "${1:---dry-run}" in
  --check)
    rc=0
    cmp -s "$tool_src" "$tool_dst" || { printf '%s\n' "rex-safe-upgrade missing or differs: $tool_dst" >&2; rc=1; }
    cmp -s "$ext_src" "$ext_dst" || { printf '%s\n' "Pi pane recorder missing or differs: $ext_dst" >&2; rc=1; }
    [ $rc = 0 ] && printf '%s\n' 'rex-safe-upgrade and Pi pane recorder match source.'
    exit $rc ;;
  --dry-run)
    printf 'Would install %s -> %s\n' "$tool_src" "$tool_dst"
    printf 'Would install %s -> %s\n' "$ext_src" "$ext_dst"
    printf '%s\n' '(only with --apply)' ;;
  --apply)
    command -v python3 >/dev/null 2>&1 || { printf '%s\n' 'python3 is required.' >&2; exit 1; }
    install_one "$tool_src" "$tool_dst" 0755
    install_one "$ext_src" "$ext_dst" 0644
    printf '%s\n' 'Run /reload in open Pi sessions so they record their pane.' ;;
  *) printf '%s\n' 'usage: setup-rex-safe-upgrade.sh [--dry-run|--check|--apply]' >&2; exit 1 ;;
esac
