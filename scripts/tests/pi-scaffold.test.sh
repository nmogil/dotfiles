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

# --- ./dot pi install: installs @latest via npm, then requires >= the minimum ----
# Stub node+npm (PI_NPM_NODE/PI_NPM_CLI) install a fake npm-layout Pi reporting
# $STUB_NEW_VERSION into a temp prefix. Nothing touches the real npm or HOME.
. "$ROOT/scripts/lib/pi-cli.sh"
INSTALL_HOME="$TMP/install-home"
PREFIX="$TMP/npm-prefix"
mkdir -p "$INSTALL_HOME" "$TMP/npm-bin"
cat > "$TMP/npm-bin/node" <<'SH'
#!/bin/sh
shift  # the npm CLI path
case "$1" in
  prefix) echo "$STUB_PREFIX" ;;
  install)
    printf '%s\n' "$*" >> "$STUB_NPM_LOG"
    pkg_dir="$STUB_PREFIX/lib/node_modules/@earendil-works/pi-coding-agent/dist"
    mkdir -p "$pkg_dir" "$STUB_PREFIX/bin"
    printf '#!/bin/sh\necho %s\n' "$STUB_NEW_VERSION" > "$pkg_dir/cli.js"
    chmod +x "$pkg_dir/cli.js"
    ln -sf "$pkg_dir/cli.js" "$STUB_PREFIX/bin/pi" ;;
  *) exit 2 ;;
esac
SH
: > "$TMP/npm-bin/npm-cli.js"
chmod +x "$TMP/npm-bin/node"
pi_install() {  # pi_install <new-version> [answer]
  rm -rf "$PREFIX" "$TMP/npm.log"
  INSTALL_RC=0
  INSTALL_OUT="$(printf '%s\n' "${2:-y}" | HOME="$INSTALL_HOME" PATH="/usr/bin:/bin" \
    DOTFILES_LOCAL_ENV="$TMP/empty.env" PI_NPM_NODE="$TMP/npm-bin/node" PI_NPM_CLI="$TMP/npm-bin/npm-cli.js" \
    STUB_PREFIX="$PREFIX" STUB_NPM_LOG="$TMP/npm.log" STUB_NEW_VERSION="$1" \
    bash "$ROOT/scripts/setup-pi-agent.sh" --install 2>&1)" || INSTALL_RC=$?
}
pi_install 99.0.0
[ "$INSTALL_RC" = 0 ] \
  && [ "$(cat "$TMP/npm.log")" = "install -g --prefix $PREFIX @earendil-works/pi-coding-agent@latest" ] \
  && printf '%s\n' "$INSTALL_OUT" | grep -Fq 'Pi npm installation active' \
  || { printf '%s\n' "$INSTALL_OUT"; echo 'FAIL pi install: installs @latest and accepts a newer Pi'; exit 1; }
pi_install "$PI_MIN_VERSION"
[ "$INSTALL_RC" = 0 ] \
  || { printf '%s\n' "$INSTALL_OUT"; echo 'FAIL pi install: accepts Pi equal to the minimum'; exit 1; }
pi_install 0.0.1
[ "$INSTALL_RC" != 0 ] \
  && printf '%s\n' "$INSTALL_OUT" | grep -Fq "older than the minimum $PI_MIN_VERSION" \
  || { printf '%s\n' "$INSTALL_OUT"; echo 'FAIL pi install: refuses a Pi older than the minimum'; exit 1; }
pi_install 99.0.0 n
[ "$INSTALL_RC" = 0 ] && [ ! -e "$TMP/npm.log" ] \
  && printf '%s\n' "$INSTALL_OUT" | grep -Fq 'npm install -g @earendil-works/pi-coding-agent@latest' \
  || { printf '%s\n' "$INSTALL_OUT"; echo 'FAIL pi install: declining installs nothing'; exit 1; }
# An active npm-layout Pi at or above the minimum is kept (./dot update keeps it
# current); one below the minimum is replaced with the latest.
pi_install 99.0.0
active() {  # active <current-version>: rerun --install with that Pi on PATH
  printf '#!/bin/sh\necho %s\n' "$1" > "$PREFIX/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
  rm -f "$TMP/npm.log"
  INSTALL_RC=0
  INSTALL_OUT="$(printf 'y\n' | HOME="$INSTALL_HOME" PATH="$PREFIX/bin:/usr/bin:/bin" \
    DOTFILES_LOCAL_ENV="$TMP/empty.env" PI_NPM_NODE="$TMP/npm-bin/node" PI_NPM_CLI="$TMP/npm-bin/npm-cli.js" \
    STUB_PREFIX="$PREFIX" STUB_NPM_LOG="$TMP/npm.log" STUB_NEW_VERSION=99.0.0 \
    bash "$ROOT/scripts/setup-pi-agent.sh" --install 2>&1)" || INSTALL_RC=$?
}
active "$PI_MIN_VERSION"
[ "$INSTALL_RC" = 0 ] && [ ! -e "$TMP/npm.log" ] \
  && printf '%s\n' "$INSTALL_OUT" | grep -Fq 'Pi npm installation already active' \
  || { printf '%s\n' "$INSTALL_OUT"; echo 'FAIL pi install: keeps an active Pi at the minimum'; exit 1; }
active 0.0.1
[ "$INSTALL_RC" = 0 ] && [ -s "$TMP/npm.log" ] \
  && printf '%s\n' "$INSTALL_OUT" | grep -Fq "Pi 0.0.1 is older than the minimum $PI_MIN_VERSION" \
  || { printf '%s\n' "$INSTALL_OUT"; echo 'FAIL pi install: replaces an active Pi below the minimum'; exit 1; }
printf '%s\n' 'ok   pi install: npm @latest, newer/equal accepted, older refused/replaced, declining installs nothing'
