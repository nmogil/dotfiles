#!/usr/bin/env bash
# Real doctor entrypoint: accept floating compaction and flag stale pins.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SCAFFOLD="$TMP/scaffold"
mkdir -p "$SCAFFOLD/agent" "$TMP/home"
: > "$TMP/empty.env"
printf '%s\n' '{"private":true}' > "$SCAFFOLD/package.json"
printf '%s\n' '{}' > "$SCAFFOLD/agent/pi-codex-compaction.json"
check_source() {
  printf '{"packages":["%s"]}\n' "$1" > "$SCAFFOLD/agent/settings.example.json"
  HOME="$TMP/home" DOTFILES_LOCAL_ENV="$TMP/empty.env" \
    DOTFILES_PI_SCAFFOLD_DIR="$SCAFFOLD" PI_HOME="$TMP/home/.pi" \
    "$ROOT/dot" pi doctor
}
check_source 'npm:@ogulcancelik/pi-codex-compaction' > "$TMP/floating"
grep -Fq 'ok   floating Codex compaction config present' "$TMP/floating"
for source in 'npm:@ogulcancelik/pi-codex-compaction@0.1.1' \
              'npm:@ogulcancelik/pi-codex-compaction@0.1.7'; do
  check_source "$source" > "$TMP/pinned"
  grep -Fq 'MISS floating Codex compaction config missing' "$TMP/pinned"
done
test ! -e "$TMP/home/.pi"
printf '%s\n' 'ok   doctor accepts unpinned compaction, flags exact pins, and writes no live configuration'
