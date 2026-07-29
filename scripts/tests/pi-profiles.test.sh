#!/usr/bin/env bash
# Integration test for the public Pi profile installer. Uses a temp HOME and
# verifies profile separation through the real `./dot pi profiles` entrypoint.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The scaffold is not tracked in this public repo. Use the caller's configured
# source (or a fork-local templates/pi) and skip cleanly when neither exists —
# the profile installer cannot run without its source assets.
# shellcheck source=../lib/local-env.sh
. "$ROOT/scripts/lib/local-env.sh"
load_local_env || true
SCAFFOLD="${DOTFILES_PI_SCAFFOLD_DIR:-$ROOT/templates/pi}"
if [ ! -f "$SCAFFOLD/agent/cloak.json" ]; then
  printf '%s\n' 'skip Pi profiles test (no scaffold source; set DOTFILES_PI_SCAFFOLD_DIR)'
  exit 0
fi
export DOTFILES_PI_SCAFFOLD_DIR="$SCAFFOLD"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PERSONAL="$TMP/.pi/agent"
WORK="$TMP/.pi/agent-clientx"
mkdir -p "$PERSONAL/extensions" "$PERSONAL/skills" "$PERSONAL/themes" \
  "$PERSONAL/npm" "$TMP/.config/dotfiles"

cat > "$PERSONAL/settings.json" <<'JSON'
{
  "defaultProvider": "openai-codex",
  "defaultModel": "gpt-5.6-sol",
  "privateMarker": "must-not-cross-profile-boundary"
}
JSON
printf '%s\n' '{"privateMarker":"must-not-cross-profile-boundary"}' > "$PERSONAL/cloak.json"
printf '%s\n' '{"anthropic":{"type":"api_key","key":"must-not-copy"}}' > "$PERSONAL/auth.json"
printf '%s\n' 'DOTFILES_PI_WORK_PROFILE_SLUG="clientx"' > "$TMP/.config/dotfiles/local.env"

HOME="$TMP" "$ROOT/dot" pi profiles --apply >/dev/null
HOME="$TMP" "$ROOT/dot" pi profiles --apply >/dev/null
HOME="$TMP" "$ROOT/dot" pi profiles --check >/dev/null

test -d "$WORK"
test ! -e "$WORK/auth.json"
test "$(readlink -f "$WORK/extensions")" = "$(readlink -f "$PERSONAL/extensions")"
test "$(readlink -f "$WORK/skills")" = "$(readlink -f "$PERSONAL/skills")"
cmp -s "$SCAFFOLD/agent/cloak.json" "$WORK/cloak.json"

python3 - "$WORK/settings.json" "$WORK/models.json" <<'PY'
import json
import sys
from pathlib import Path

settings = json.loads(Path(sys.argv[1]).read_text())
assert settings == {
    "defaultProvider": "anthropic",
    "defaultModel": "claude-sonnet-4-6",
}
models = json.loads(Path(sys.argv[2]).read_text())
overrides = models["providers"]["anthropic"]["modelOverrides"]
assert overrides
assert all(item["name"].startswith("Clientx · ") for item in overrides.values())
assert "must-not-cross-profile-boundary" not in json.dumps({"settings": settings, "models": models})
PY

printf '%s\n' 'ok   Pi profiles are idempotent and keep settings/auth/Cloak boundaries'
