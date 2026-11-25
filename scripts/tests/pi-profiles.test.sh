#!/usr/bin/env bash
# Integration test for the public Pi profile installer. Uses a temp HOME and
# verifies profile separation through the real `./dot pi profiles` entrypoint.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- no work Pi profile while rexume is installed (docs/rexume.md) ---------------------
# rexume reopens Pi without PI_CODING_AGENT_DIR, and its extension would load in
# a work profile through the shared extensions, so the two never coexist. These
# cases use a minimal fixture scaffold, so they run even where the real scaffold
# is absent (CI).
RX="$(mktemp -d)"
trap 'rm -rf "$RX"' EXIT
FIX="$RX/scaffold"
mkdir -p "$FIX/agent/extensions" "$FIX/agent/skills/coding-agent-account-routing"
printf '%s\n' '// badge' > "$FIX/agent/extensions/account-profile-indicator.ts"
printf '%s\n' '---' 'name: coding-agent-account-routing' '---' > "$FIX/agent/skills/coding-agent-account-routing/SKILL.md"
printf '%s\n' '{"providers":{"anthropic":{"modelOverrides":{"m":{"name":"Work · Sonnet"}}}}}' > "$FIX/agent/models.work.example.json"
printf '%s\n' '{}' > "$FIX/agent/cloak.json"
# The caller's PATH without any directory holding a rexume (a dev machine may have one).
RX_PATH=""
rest="$PATH:"
while [ -n "$rest" ]; do
  dir="${rest%%:*}"; rest="${rest#*:}"
  [ -n "$dir" ] && [ ! -e "$dir/rexume" ] && RX_PATH="${RX_PATH:+$RX_PATH:}$dir"
done
rx_home() {  # rx_home <dir>: a HOME with a personal profile (with extensions) and local.env
  mkdir -p "$1/.pi/agent/extensions" "$1/.config/dotfiles"
  printf '%s\n' 'DOTFILES_PI_WORK_PROFILE_SLUG="clientx"' 'DOTFILES_ENABLE_HERMES=0' > "$1/.config/dotfiles/local.env"
}
rx_profiles() {  # rx_profiles <home> <flag>: ./dot pi profiles pinned to the fixture HOME
  HOME="$1" PI_HOME="${RX_PI_HOME:-$1/.pi}" XDG_CONFIG_HOME="$1/.config" DOTFILES_LOCAL_ENV="$1/.config/dotfiles/local.env" \
    HERMES_HOME="$1/.hermes" \
    DOTFILES_PI_SCAFFOLD_DIR="$FIX" DOTFILES_PROFILES_LOCK_TIMEOUT="${RX_LOCK_TIMEOUT:-10}" PATH="$RX_PATH" \
    ${RX_EXEC:+exec} "$ROOT/dot" pi profiles "$2" > "$RX/out" 2>&1
}
rx_fail() { printf 'FAIL %s\n' "$1"; sed 's/^/       /' "$RX/out"; exit 1; }
rx_refuses_work_profile() {  # rx_refuses_work_profile <home> <name>
  if rx_profiles "$1" --apply; then rx_fail "$2: pi profiles --apply created a work profile next to rexume"; fi
  grep -Fq 'while rexume is installed' "$RX/out" && grep -Fq 'docs/rexume.md' "$RX/out" \
    || rx_fail "$2: pi profiles --apply explains the rexume refusal"
  [ ! -e "$1/.pi/agent-clientx" ] || rx_fail "$2: pi profiles --apply created $1/.pi/agent-clientx"
  printf 'ok   %s\n' "$2"
}

# rexume first: --apply refuses to create a work profile, whichever trace rexume left.
H="$RX/ext"; rx_home "$H"; printf '%s\n' '// Written by `rexume install`' > "$H/.pi/agent/extensions/rexume.ts"
rx_refuses_work_profile "$H" "rexume first (its Pi extension): no work profile"
H="$RX/bin"; rx_home "$H"; mkdir -p "$H/.local/bin"; printf '#!/bin/sh\n' > "$H/.local/bin/rexume"; chmod 755 "$H/.local/bin/rexume"
rx_refuses_work_profile "$H" "rexume first (its binary): no work profile"
H="$RX/unit"; rx_home "$H"; mkdir -p "$H/.config/systemd/user"; : > "$H/.config/systemd/user/rexume.service"
rx_refuses_work_profile "$H" "rexume first (its systemd unit): no work profile"
H="$RX/agent"; rx_home "$H"; mkdir -p "$H/Library/LaunchAgents"; : > "$H/Library/LaunchAgents/io.github.entwining.rexume.plist"
rx_refuses_work_profile "$H" "rexume first (its LaunchAgent): no work profile"

# Profiles first, then rexume appears: --check flags the combination; --apply refuses.
H="$RX/profiles-first"; rx_home "$H"
rx_profiles "$H" --apply || rx_fail "pi profiles --apply (fixture scaffold) succeeds without rexume"
[ -L "$H/.pi/agent-clientx/extensions" ] || rx_fail "pi profiles --apply shares extensions without rexume"
[ ! -e "$H/.pi/.dotfiles-profiles.lock" ] || rx_fail "pi profiles --apply releases the profiles lock"
mkdir -p "$H/.local/bin"; printf '#!/bin/sh\n' > "$H/.local/bin/rexume"; chmod 755 "$H/.local/bin/rexume"
if rx_profiles "$H" --check; then rx_fail "pi profiles --check passes with rexume and a work profile"; fi
grep -Fq 'rexume is installed' "$RX/out" && grep -Fq 'docs/rexume.md' "$RX/out" \
  || rx_fail "pi profiles --check explains the rexume + work profile combination"
if rx_profiles "$H" --apply; then rx_fail "pi profiles --apply passes with rexume and a work profile"; fi
printf '%s\n' 'ok   profiles first: --check flags rexume + work profile, --apply refuses'

# The profiles lock: a live holder makes --apply refuse within the timeout; nothing is created.
H="$RX/locked"; rx_home "$H"
sleep 30 & HOLDER=$!
mkdir "$H/.pi/.dotfiles-profiles.lock"; echo "$HOLDER" > "$H/.pi/.dotfiles-profiles.lock/pid"
t0="$(date +%s)"
if RX_LOCK_TIMEOUT=1 rx_profiles "$H" --apply; then rx_fail "pi profiles --apply ran while the profiles lock was held"; fi
t1="$(date +%s)"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null || true
grep -Fq "holds $H/.pi/.dotfiles-profiles.lock (pid $HOLDER)" "$RX/out" || rx_fail "pi profiles --apply names the lock holder"
[ ! -e "$H/.pi/agent-clientx" ] && [ $((t1 - t0)) -lt 8 ] || rx_fail "pi profiles --apply waited too long or wrote under the lock"
printf '%s\n' 'ok   pi profiles --apply refuses (bounded) while ./dot rexume holds the profiles lock'

# PI_HOME elsewhere: the lock is still ~/.pi's (rexume supports only the default
# root), and rexume under the default root still blocks a work profile.
H="$RX/override"; rx_home "$H"; mkdir -p "$H/custom-pi/agent/extensions"
sleep 30 & HOLDER=$!
mkdir "$H/.pi/.dotfiles-profiles.lock"; echo "$HOLDER" > "$H/.pi/.dotfiles-profiles.lock/pid"
if RX_PI_HOME="$H/custom-pi" RX_LOCK_TIMEOUT=1 rx_profiles "$H" --apply; then rx_fail "PI_HOME override: --apply ignored the ~/.pi lock"; fi
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null || true
grep -Fq "holds $H/.pi/.dotfiles-profiles.lock" "$RX/out" && [ ! -e "$H/custom-pi/.dotfiles-profiles.lock" ] \
  && [ ! -e "$H/custom-pi/agent-clientx" ] || rx_fail "PI_HOME override: the lock is always ~/.pi/.dotfiles-profiles.lock"
rm -rf "$H/.pi/.dotfiles-profiles.lock"
printf '%s\n' '// Written by `rexume install`' > "$H/.pi/agent/extensions/rexume.ts"
if RX_PI_HOME="$H/custom-pi" rx_profiles "$H" --apply; then rx_fail "PI_HOME override: --apply ignored rexume under ~/.pi"; fi
grep -Fq 'while rexume is installed' "$RX/out" && [ ! -e "$H/custom-pi/agent-clientx" ] \
  || rx_fail "PI_HOME override: rexume under the default root blocks a work profile"
printf '%s\n' 'ok   PI_HOME override: the lock and rexume detection stay on ~/.pi'

# A one-off custom PI_HOME: profile setup records its root (canonical) in
# ~/.pi/.dotfiles-profile-roots, and a later default `./dot rexume` (PI_HOME
# unset) sees the custom work profile and refuses. The rexume run is its
# read-only dry run (it writes nothing and never installs).
H="$RX/custom-root"; rx_home "$H"; mkdir -p "$H/custom-pi/agent/extensions"
RX_PI_HOME="$H/custom-pi" rx_profiles "$H" --apply || rx_fail "custom root: pi profiles --apply"
[ -d "$H/custom-pi/agent-clientx" ] || rx_fail "custom root: work profile created under PI_HOME"
grep -Fxq "$(cd -P "$H/custom-pi" && pwd -P)" "$H/.pi/.dotfiles-profile-roots" \
  || rx_fail "custom root: recorded in ~/.pi/.dotfiles-profile-roots"
RX_PI_HOME="$H/custom-pi" rx_profiles "$H" --apply || rx_fail "custom root: second --apply"
[ "$(grep -c . "$H/.pi/.dotfiles-profile-roots")" = 1 ] || rx_fail "custom root: recorded once"
env -u PI_HOME HOME="$H" XDG_CONFIG_HOME="$H/.config" DOTFILES_LOCAL_ENV="$H/.config/dotfiles/local.env" PATH="$RX_PATH" \
  "$ROOT/dot" rexume --dry-run > "$RX/out" 2>&1 || rx_fail "custom root: ./dot rexume --dry-run"
grep -Fq 'would refuse' "$RX/out" && grep -Fq 'custom-pi' "$RX/out" && grep -Fq 'agent-clientx' "$RX/out" \
  || rx_fail "custom root: a later default ./dot rexume sees the custom work profile"
printf '%s\n' 'ok   a custom-root work profile is registered and blocks a later default rexume'

# CDPATH: a relative PI_HOME resolves against the current directory, never a
# CDPATH entry with the same name; registration and every write use that one
# absolute path.
H="$RX/cdpath"; rx_home "$H"
mkdir -p "$H/cwd/rel-pi/agent/extensions" "$H/decoy/rel-pi/agent/extensions"
if ! (cd "$H/cwd" && CDPATH="$H/decoy" HOME="$H" PI_HOME=rel-pi XDG_CONFIG_HOME="$H/.config" \
    DOTFILES_LOCAL_ENV="$H/.config/dotfiles/local.env" HERMES_HOME="$H/.hermes" DOTFILES_PI_SCAFFOLD_DIR="$FIX" \
    PATH="$RX_PATH" "$ROOT/dot" pi profiles --apply) > "$RX/out" 2>&1; then
  rx_fail "CDPATH: pi profiles --apply with a relative PI_HOME"
fi
[ "$(cat "$H/.pi/.dotfiles-profile-roots")" = "$(cd -P "$H/cwd/rel-pi" && pwd -P)" ] \
  && [ -d "$H/cwd/rel-pi/agent-clientx" ] && [ ! -e "$H/decoy/rel-pi/agent-clientx" ] \
  || rx_fail "CDPATH: the registry and the work profile use the cwd's rel-pi, not CDPATH's"
printf '%s\n' 'ok   CDPATH never redirects a relative PI_HOME (registry and writes agree)'

# The registry must be a regular file (not a symlink, FIFO or directory); it
# is never read or appended through anything else. Bounded: a FIFO would block.
bounded_profiles() {  # bounded_profiles <home>: rx_profiles --apply, KILLed after 10 s
  # RX_EXEC: the background subshell becomes ./dot (which execs the installer),
  # so the kill reaches the installer itself, not a wrapper.
  (RX_EXEC=1 rx_profiles "$1" --apply) & bp=$!
  ( sleep 10; kill -KILL "$bp" 2>/dev/null ) >/dev/null 2>&1 & bw=$!
  wait "$bp"; brc=$?
  kill "$bw" 2>/dev/null; wait "$bw" 2>/dev/null
  return "$brc"
}
for kind in symlink fifo dir; do
  H="$RX/reg-$kind"; rx_home "$H"; : > "$RX/reg-target-$kind"
  case "$kind" in
    symlink) ln -s "$RX/reg-target-$kind" "$H/.pi/.dotfiles-profile-roots" ;;
    fifo) mkfifo "$H/.pi/.dotfiles-profile-roots" ;;
    dir) mkdir "$H/.pi/.dotfiles-profile-roots" ;;
  esac
  if bounded_profiles "$H"; then rx_fail "registry $kind: pi profiles --apply went ahead"; fi
  grep -Fq 'not a regular file' "$RX/out" && [ ! -s "$RX/reg-target-$kind" ] && [ ! -e "$H/.pi/agent-clientx" ] \
    || rx_fail "registry $kind: refused clearly, nothing written"
done
printf '%s\n' 'ok   a symlinked, FIFO or directory registry is refused before reading or appending'

# No newline in PI_HOME or its resolved path: the registry is line-based, and
# command substitution would drop a trailing newline (writing to a different
# directory). Both dirs exist, so a resolution that drops it would go ahead.
NL='
'
H="$RX/nl"; rx_home "$H"; mkdir -p "$H/trail$NL/agent/extensions" "$H/trail/agent/extensions" "$H/in${NL}side/agent/extensions"
for bad in "$H/trail$NL" "$H/in${NL}side"; do
  if RX_PI_HOME="$bad" rx_profiles "$H" --apply; then rx_fail "newline PI_HOME: pi profiles --apply went ahead"; fi
  grep -Fq 'newline' "$RX/out" && [ ! -e "$H/.pi/.dotfiles-profile-roots" ] && [ ! -e "$H/trail/agent-clientx" ] \
    && [ ! -e "$H/trail$NL/agent-clientx" ] && [ ! -e "$H/in${NL}side/agent-clientx" ] \
    || rx_fail "newline PI_HOME: refused, nothing recorded or written"
done
ln -s "trail$NL" "$H/trail-link"
if RX_PI_HOME="$H/trail-link" rx_profiles "$H" --apply; then rx_fail "newline in the resolved path: --apply went ahead"; fi
grep -Fq 'newline' "$RX/out" && [ ! -e "$H/trail/agent-clientx" ] && [ ! -e "$H/.pi/.dotfiles-profile-roots" ] \
  || rx_fail "newline in the resolved path: refused, nothing recorded or written"
printf '%s\n' 'ok   a newline in PI_HOME or its resolved path is refused'

# A mixed-case work profile still counts for --check.
H="$RX/mixed"; rx_home "$H"; mkdir -p "$H/.pi/AGENT-OTHER" "$H/.local/bin"
printf '#!/bin/sh\n' > "$H/.local/bin/rexume"; chmod 755 "$H/.local/bin/rexume"
if rx_profiles "$H" --check; then rx_fail "mixed case: --check passed"; fi
grep -Fq "AGENT-OTHER" "$RX/out" && grep -Fq 'rexume is installed' "$RX/out" || rx_fail "mixed case: --check flags rexume + AGENT-OTHER"
printf '%s\n' 'ok   a mixed-case work profile (AGENT-OTHER) is flagged with rexume'
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

# Every run is pinned to the fixture HOME: an inherited PI_HOME, XDG_CONFIG_HOME,
# DOTFILES_LOCAL_ENV or HERMES_HOME would point the installer at real files.
profiles() {
  HOME="$TMP" PI_HOME="$TMP/.pi" XDG_CONFIG_HOME="$TMP/.config" \
    DOTFILES_LOCAL_ENV="$TMP/.config/dotfiles/local.env" HERMES_HOME="$TMP/.hermes" PATH="$RX_PATH" \
    "$ROOT/dot" pi profiles "$1" >/dev/null
}
profiles --apply
profiles --apply
profiles --check

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
profiles --apply
profiles --check
test -f "$TMP/.hermes/skills/software-development/coding-agent-account-routing/SKILL.md"

printf '%s\n' 'ok   Pi profiles are idempotent and keep settings/auth/Cloak boundaries'
