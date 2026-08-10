#!/usr/bin/env bash
# Verify scaffold application excludes dependency/runtime trees.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/scaffold"
DEST="$TMP/home/.pi"
mkdir -p "$SRC/agent/extensions" "$SRC/node_modules/example" \
  "$SRC/agent/npm/example" "$SRC/.git/objects" "$SRC/agent/sessions/example"
printf '%s\n' '{"name":"test-scaffold","private":true}' > "$SRC/package.json"
printf '%s\n' 'portable' > "$SRC/agent/extensions/portable.ts"
printf '%s\n' 'dependency' > "$SRC/node_modules/example/index.js"
printf '%s\n' 'runtime package' > "$SRC/agent/npm/example/index.js"
printf '%s\n' 'git state' > "$SRC/.git/objects/object"
printf '%s\n' 'session state' > "$SRC/agent/sessions/example/session.json"
: > "$TMP/empty.env"

DOTFILES_LOCAL_ENV="$TMP/empty.env" DOTFILES_PI_SCAFFOLD_DIR="$SRC" PI_HOME="$DEST" \
  "$ROOT/dot" pi scaffold --apply >/dev/null

test -f "$DEST/package.json"
test -f "$DEST/agent/extensions/portable.ts"
test ! -e "$DEST/node_modules"
test ! -e "$DEST/agent/npm"
test ! -e "$DEST/.git"
test ! -e "$DEST/agent/sessions"

printf '%s\n' 'ok   Pi scaffold excludes dependencies and runtime state'
