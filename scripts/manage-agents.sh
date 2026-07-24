#!/usr/bin/env bash
# Read-only inventory and policy checks for local AI-agent capabilities.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/local-env.sh
. "$ROOT/scripts/lib/local-env.sh"
dotfiles_load_config

exec python3 "$ROOT/scripts/manage-agents.py" "$@"
