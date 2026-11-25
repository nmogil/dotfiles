#!/usr/bin/env bash
# Tests for the shared Pi CLI helpers (scripts/lib/pi-cli.sh): the minimum-version
# compare (numeric x.y.z, works on macOS /bin/bash 3.2) and the gates that use
# it through `./dot packages check` and `./dot pi doctor`. Hermetic: temp HOME,
# a stub npm-layout `pi`, and a PATH without Homebrew.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); [ -z "${OUT:-}" ] || printf '%s\n' "$OUT" | sed 's/^/     | /'; }

# shellcheck source=../lib/pi-cli.sh
. "$ROOT/scripts/lib/pi-cli.sh" || { echo "FAIL cannot source scripts/lib/pi-cli.sh"; exit 1; }

# --- pi_version_at_least <installed> <minimum> -----------------------------------
at_least() { pi_version_at_least "$1" "$2"; }
expect_yes() { if at_least "$1" "$2"; then ok "$1 >= $2"; else bad "$1 >= $2"; fi; }
expect_no()  { if at_least "$1" "$2"; then bad "$1 is not >= $2"; else ok "$1 is not >= $2"; fi; }
expect_yes 1.6.0 1.6.0       # equal
expect_yes 1.6.1 1.6.0       # newer patch
expect_yes 1.7.0 1.6.9       # newer minor
expect_yes 2.0.0 1.99.99     # newer major
expect_no  1.5.9 1.6.0       # older
expect_no  1.6.0 1.6.1
expect_no  0.81.1 1.6.0
expect_yes 1.10.0 1.9.0      # numeric, not lexical
expect_no  1.9.0 1.10.0
expect_yes 1.6.10 1.6.9
expect_yes 1.08.0 1.7.0      # leading zeros are decimal, not octal
for junk in '' 1.6 1.6.0.1 v1.6.0 1.6.0-beta.1 'pi 1.6.0' 1.x.0 ' 1.6.0'; do
  if at_least "$junk" 1.0.0; then bad "unparsable installed '$junk' is refused"; else ok "unparsable installed '$junk' is refused"; fi
done
if at_least 1.6.0 bogus; then bad "unparsable minimum is refused"; else ok "unparsable minimum is refused"; fi
case "$PI_MIN_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ok "PI_MIN_VERSION is x.y.z ($PI_MIN_VERSION)" ;;
  *) bad "PI_MIN_VERSION is x.y.z ($PI_MIN_VERSION)" ;;
esac

# --- fixtures for ./dot ----------------------------------------------------------
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/other" || exit 2
: > "$TMP/empty.env"
export DOTFILES_LOCAL_ENV="$TMP/empty.env" DOTFILES_PI_SCAFFOLD_DIR="$TMP/no-scaffold" \
  DOTFILES_PI_CONFIG_DIR="$TMP/no-pi-config" DOTFILES_PI_BLOCKLIST="$TMP/no-blocklist"
NPM_PI="$TMP/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
mkdir -p "$(dirname "$NPM_PI")" || exit 2
printf '%s\n' '#!/bin/sh' 'echo "${STUB_PI_VERSION:-0.0.0}"' > "$NPM_PI"
cp "$NPM_PI" "$TMP/other/pi"
chmod +x "$NPM_PI" "$TMP/other/pi"
ln -s "$NPM_PI" "$TMP/bin/pi"
# npm: present (enables the npm.global section); every other package is missing.
printf '%s\n' '#!/bin/sh' 'exit 1' > "$TMP/bin/npm" && chmod +x "$TMP/bin/npm"
NODE="$(command -v node)" && ln -s "$NODE" "$TMP/bin/node" || { echo "FAIL node is required"; exit 1; }
HPATH="$TMP/bin:/usr/bin:/bin"
PKG="@earendil-works/pi-coding-agent"

packages() { OUT="$(PATH="$HPATH" STUB_PI_VERSION="$1" "$ROOT/dot" packages check 2>&1)"; }
pi_line() { printf '%s\n' "$OUT" | grep -F -- "$PKG"; }

grep -Eq "^$PKG(@latest)?([[:space:]]|$)" "$ROOT/packages/npm.global" \
  && ! grep -Eq "^$PKG@[0-9]" "$ROOT/packages/npm.global" \
  && ok "packages/npm.global lists Pi unpinned or @latest" \
  || bad "packages/npm.global lists Pi unpinned or @latest"

packages "$PI_MIN_VERSION"
pi_line | grep -Eq "^  ok   $PKG.*$PI_MIN_VERSION" \
  && ok "packages check: Pi equal to the minimum is ok" || bad "packages check: Pi equal to the minimum is ok"
packages 99.0.0
pi_line | grep -Eq "^  ok   $PKG.*99\.0\.0.*minimum $PI_MIN_VERSION" \
  && ok "packages check: newer Pi is ok and names the minimum" || bad "packages check: newer Pi is ok and names the minimum"
packages 0.0.1
pi_line | grep -Eq "^  MISMATCH $PKG.*0\.0\.1.*older than the minimum $PI_MIN_VERSION.*pi update" \
  && ok "packages check: older Pi is a mismatch that says to run pi update" \
  || bad "packages check: older Pi is a mismatch that says to run pi update"
OUT="$(PATH="$TMP/other:$HPATH" STUB_PI_VERSION=99.0.0 "$ROOT/dot" packages check 2>&1)"
pi_line | grep -Eq "^  MISMATCH $PKG.*not the required npm package layout" \
  && ok "packages check: a non-npm-layout Pi is a mismatch even when new enough" \
  || bad "packages check: a non-npm-layout Pi is a mismatch even when new enough"

doctor() { OUT="$(PATH="${2:-$HPATH}" STUB_PI_VERSION="$1" "$ROOT/dot" pi doctor 2>&1)"; }
doctor 99.0.0
printf '%s\n' "$OUT" | grep -Eq "ok   Pi CLI present: .*99\.0\.0.*minimum $PI_MIN_VERSION" \
  && ok "pi doctor: newer Pi is ok" || bad "pi doctor: newer Pi is ok"
doctor "$PI_MIN_VERSION"
printf '%s\n' "$OUT" | grep -Fq "ok   Pi CLI present: " \
  && ok "pi doctor: Pi equal to the minimum is ok" || bad "pi doctor: Pi equal to the minimum is ok"
doctor 0.0.1
printf '%s\n' "$OUT" | grep -Eq "WARN Pi 0\.0\.1 is older than the minimum $PI_MIN_VERSION.*pi update" \
  && ok "pi doctor: older Pi warns and says to run pi update" || bad "pi doctor: older Pi warns and says to run pi update"
doctor 99.0.0 "$TMP/other:$HPATH"
printf '%s\n' "$OUT" | grep -Fq "WARN Pi 99.0.0 is not the required npm package layout" \
  && ok "pi doctor: a non-npm-layout Pi warns" || bad "pi doctor: a non-npm-layout Pi warns"

printf '\n== pi-version tests: %d pass, %d fail ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
