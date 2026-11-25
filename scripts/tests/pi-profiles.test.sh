#!/usr/bin/env bash
# Integration test for the public Pi profile installer. Uses a temp HOME and
# verifies profile separation through the real `./dot pi profiles` entrypoint.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- rexume's Pi extension never reaches the work profile -------------------------------
# rexume (docs/rexume.md) writes ~/.pi/agent/extensions/rexume.ts, and it must
# never load in a work profile. These cases use a minimal fixture scaffold, so
# they run even where the real scaffold is absent (CI).
RX="$(mktemp -d)"
trap 'rm -rf "$RX"' EXIT
FIX="$RX/scaffold"
mkdir -p "$FIX/agent/extensions" "$FIX/agent/skills/coding-agent-account-routing"
printf '%s\n' '// badge' > "$FIX/agent/extensions/account-profile-indicator.ts"
printf '%s\n' '---' 'name: coding-agent-account-routing' '---' > "$FIX/agent/skills/coding-agent-account-routing/SKILL.md"
printf '%s\n' '{"providers":{"anthropic":{"modelOverrides":{"m":{"name":"Work · Sonnet"}}}}}' > "$FIX/agent/models.work.example.json"
printf '%s\n' '{}' > "$FIX/agent/cloak.json"
rx_home() {  # rx_home <dir>: a HOME with a personal profile (with extensions) and local.env
  mkdir -p "$1/.pi/agent/extensions" "$1/.config/dotfiles"
  printf '%s\n' 'DOTFILES_PI_WORK_PROFILE_SLUG="clientx"' 'DOTFILES_ENABLE_HERMES=0' > "$1/.config/dotfiles/local.env"
}
rx_profiles() { HOME="$1" XDG_CONFIG_HOME="$1/.config" DOTFILES_LOCAL_ENV="$1/.config/dotfiles/local.env" DOTFILES_PI_SCAFFOLD_DIR="$FIX" "$ROOT/dot" pi profiles "$2" > "$RX/out" 2>&1; }
rx_fail() { printf 'FAIL %s\n' "$1"; sed 's/^/       /' "$RX/out"; exit 1; }

# rexume installed first: --apply must not link the work extensions to it.
H="$RX/rexume-first"; rx_home "$H"; printf '%s\n' '// Written by `rexume install`' > "$H/.pi/agent/extensions/rexume.ts"
if rx_profiles "$H" --apply; then rx_fail "pi profiles --apply links the work extensions while rexume.ts is there"; fi
grep -Fq 'rexume.ts' "$RX/out" && grep -Fq 'docs/rexume.md' "$RX/out" \
  || rx_fail "pi profiles --apply explains the rexume.ts refusal"
[ ! -e "$H/.pi/agent-clientx/extensions" ] && [ ! -L "$H/.pi/agent-clientx/extensions" ] \
  || rx_fail "pi profiles --apply created a work extensions link next to rexume.ts"
if rx_profiles "$H" --check; then rx_fail "pi profiles --check passes while rexume.ts blocks the extensions link"; fi
grep -Fq 'rexume.ts' "$RX/out" || rx_fail "pi profiles --check names rexume.ts"
printf '%s\n' 'ok   rexume first: pi profiles --apply refuses to share extensions holding rexume.ts'

# Profiles first, then rexume.ts appears behind the existing link: --check and --apply fail.
H="$RX/profiles-first"; rx_home "$H"
rx_profiles "$H" --apply || rx_fail "pi profiles --apply (fixture scaffold) succeeds without rexume"
[ -L "$H/.pi/agent-clientx/extensions" ] || rx_fail "pi profiles --apply shares extensions without rexume"
printf '%s\n' '// Written by `rexume install`' > "$H/.pi/agent/extensions/rexume.ts"
if rx_profiles "$H" --check; then rx_fail "pi profiles --check passes while the work profile loads rexume.ts"; fi
grep -Fq 'rexume.ts' "$RX/out" && grep -Fq 'docs/rexume.md' "$RX/out" \
  || rx_fail "pi profiles --check explains that the work profile loads rexume.ts"
if rx_profiles "$H" --apply; then rx_fail "pi profiles --apply passes while the work profile loads rexume.ts"; fi
printf '%s\n' 'ok   profiles first: pi profiles --check/--apply fail once the shared extensions hold rexume.ts'
rm -rf "$RX"; trap - EXIT

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
  "$PERSONAL/npm" "$PERSONAL/pi-codex-subagents/agents" \
  "$TMP/.config/dotfiles"

cat > "$PERSONAL/settings.json" <<'JSON'
{
  "defaultProvider": "openai-codex",
  "defaultModel": "gpt-5.6-sol",
  "privateMarker": "must-not-cross-profile-boundary"
}
JSON
printf '%s\n' '{"privateMarker":"must-not-cross-profile-boundary"}' > "$PERSONAL/cloak.json"
printf '%s\n' '{"anthropic":{"type":"api_key","key":"must-not-copy"}}' > "$PERSONAL/auth.json"
printf '%s\n' '{"retentionDays":7}' > "$PERSONAL/pi-codex-subagents/config.json"
printf '%s\n' 'child system prompt' > "$PERSONAL/pi-codex-subagents/SYSTEM.md"
printf '%s\n' '---' 'name: engineer' '---' 'engineer' \
  > "$PERSONAL/pi-codex-subagents/agents/engineer.md"
printf '%s\n' \
  'DOTFILES_PI_WORK_PROFILE_SLUG="clientx"' \
  'DOTFILES_ENABLE_HERMES=0' \
  > "$TMP/.config/dotfiles/local.env"

HOME="$TMP" "$ROOT/dot" pi profiles --apply >/dev/null
HOME="$TMP" "$ROOT/dot" pi profiles --apply >/dev/null
HOME="$TMP" "$ROOT/dot" pi profiles --check >/dev/null

test -d "$WORK"
test ! -e "$WORK/auth.json"
test "$(readlink -f "$WORK/extensions")" = "$(readlink -f "$PERSONAL/extensions")"
test "$(readlink -f "$WORK/skills")" = "$(readlink -f "$PERSONAL/skills")"
test ! -L "$WORK/pi-codex-subagents"
test "$(readlink -f "$WORK/pi-codex-subagents/agents")" = \
  "$(readlink -f "$PERSONAL/pi-codex-subagents/agents")"
test "$(readlink -f "$WORK/pi-codex-subagents/SYSTEM.md")" = \
  "$(readlink -f "$PERSONAL/pi-codex-subagents/SYSTEM.md")"
test "$(readlink -f "$WORK/pi-codex-subagents/config.json")" = \
  "$(readlink -f "$PERSONAL/pi-codex-subagents/config.json")"
test ! -e "$WORK/pi-codex-subagents/runs"
test ! -e "$TMP/.hermes"
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

printf '%s\n' \
  'DOTFILES_PI_WORK_PROFILE_SLUG="clientx"' \
  'DOTFILES_ENABLE_HERMES=1' \
  > "$TMP/.config/dotfiles/local.env"
HOME="$TMP" "$ROOT/dot" pi profiles --apply >/dev/null
HOME="$TMP" "$ROOT/dot" pi profiles --check >/dev/null
test -f "$TMP/.hermes/skills/software-development/coding-agent-account-routing/SKILL.md"

printf '%s\n' 'ok   Pi profiles are idempotent and keep settings/auth/Cloak boundaries'
