#!/usr/bin/env bash
# Read-only inventory and policy checks for local AI-agent capabilities.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/local-env.sh
. "$ROOT/scripts/lib/local-env.sh"
dotfiles_load_config

# manage-agents.py needs tomllib (Python >= 3.11). macOS system python3 is 3.9,
# and Homebrew's python@3.11 ships only a versioned binary, so probe for the
# first interpreter that can actually run it.
for py in python3 python3.13 python3.12 python3.11; do
  command -v "$py" >/dev/null 2>&1 || continue
  "$py" -c 'import tomllib' 2>/dev/null || continue
  exec "$py" "$ROOT/scripts/manage-agents.py" "$@"
done
echo "manage-agents: no Python >= 3.11 with tomllib found (brew install python@3.11)" >&2
exit 1
