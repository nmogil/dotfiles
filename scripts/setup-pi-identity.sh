#!/usr/bin/env bash
# Original Pi overlay: independent of the private third-party scaffold.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$ROOT/templates/pi-identity/git-identity-preflight.ts"
target_dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/extensions"
target="$target_dir/git-identity-preflight.ts"
case "${1:---dry-run}" in
  --check)
    cmp -s "$source_file" "$target" || { printf '%s\n' "Pi identity extension missing or differs: $target" >&2; exit 1; }
    printf '%s\n' 'Pi identity extension matches source.' ;;
  --dry-run)
    printf 'Would install %s -> %s (only with --apply)\n' "$source_file" "$target" ;;
  --apply)
    [ -f "$HOME/.local/share/git-identity-guard/guard.py" ] || { printf '%s\n' 'Install the Git guard first.' >&2; exit 1; }
    mkdir -p "$target_dir"
    if [ -e "$target" ] && ! cmp -s "$source_file" "$target"; then
      printf '%s\n' 'Existing extension differs; review before replacing it.' >&2; exit 1
    fi
    cp "$source_file" "$target"
    printf 'Installed %s. Run /reload in existing Pi sessions.\n' "$target" ;;
  *) printf '%s\n' 'usage: setup-pi-identity.sh [--dry-run|--check|--apply]' >&2; exit 1 ;;
esac
