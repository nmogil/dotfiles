#!/usr/bin/env bash
# Tests for the shared Pi CLI helpers (scripts/lib/pi-cli.sh): the minimum-version
# compare (numeric x.y.z, works on macOS /bin/bash 3.2), the global-npm-install
# check that reads the version from package.json without launching Pi, and the
# gates that use them through `./dot packages check` and `./dot pi doctor`.
# Hermetic: temp HOME, stub npm-layout installs, and a PATH without Homebrew.
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
expect_yes 999999.999999.999999 999999.999999.999998   # 6 digits per component
# Same grammar as scripts/lib/pi_version.py: ASCII digits, 1-6 per component.
for junk in '' 1.6 1.6.0.1 v1.6.0 1.6.0-beta.1 'pi 1.6.0' 1.x.0 ' 1.6.0' '1.6.0 ' \
  1234567.0.0 1.0.1234567 99999999999999999999.0.0 '١.٦.٠' '1.６.0' +1.6.0; do
  if at_least "$junk" 0.0.0; then bad "unparsable installed '$junk' is refused"; else ok "unparsable installed '$junk' is refused"; fi
done
if at_least 1.6.0 bogus; then bad "unparsable minimum is refused"; else ok "unparsable minimum is refused"; fi
if at_least 1.6.0 1234567.0.0; then bad "oversized minimum is refused"; else ok "oversized minimum is refused"; fi
case "$PI_MIN_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ok "PI_MIN_VERSION is x.y.z ($PI_MIN_VERSION)" ;;
  *) bad "PI_MIN_VERSION is x.y.z ($PI_MIN_VERSION)" ;;
esac
# The Python parser agrees with the bash one on every edge input above.
agree=1
for v in 1.6.0 1.08.0 999999.0.0 1234567.0.0 1.6 v1.6.0 1.6.0-beta.1 '١.٦.٠' '1.６.0' +1.6.0 ' 1.6.0'; do
  if at_least "$v" 0.0.0; then b=1; else b=0; fi
  p="$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import pi_version
try: pi_version.parse(sys.argv[2]); print(1)
except ValueError: print(0)' "$ROOT/scripts/lib" "$v")"
  [ "$b" = "$p" ] || { agree=0; OUT="bash=$b python=$p for '$v'"; }
done
[ "$agree" = 1 ] && ok "bash and Python accept exactly the same versions" || bad "bash and Python accept exactly the same versions"

# --- fixtures --------------------------------------------------------------------
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/other" || exit 2
: > "$TMP/empty.env"
export DOTFILES_LOCAL_ENV="$TMP/empty.env" DOTFILES_PI_SCAFFOLD_DIR="$TMP/no-scaffold" \
  DOTFILES_PI_CONFIG_DIR="$TMP/no-pi-config" DOTFILES_PI_BLOCKLIST="$TMP/no-blocklist"
LAUNCHES="$TMP/pi-launches"
# make_install <package-dir> <bin>: a stub Pi package (every launch is logged)
# with package.json, reached through the <bin> symlink.
make_install() {
  mkdir -p "$1/dist/bundle" "$(dirname "$2")" || exit 2
  printf '#!/bin/sh\necho "$*" >> "%s"\necho 0.0.0\n' "$LAUNCHES" > "$1/dist/bundle/cli.js"
  chmod +x "$1/dist/bundle/cli.js"
  set_version "$1" 1.6.1
  ln -s "$1/dist/bundle/cli.js" "$2"
}
set_version() {  # set_version <package-dir> <version>
  printf '{\n\t"name": "@earendil-works/pi-coding-agent",\n\t"version": "%s"\n}\n' "$2" > "$1/package.json"
}
PKGDIR="$TMP/lib/node_modules/@earendil-works/pi-coding-agent"
make_install "$PKGDIR" "$TMP/bin/pi"
printf '%s\n' '#!/bin/sh' "echo \"\$*\" >> \"$LAUNCHES\"" 'echo 99.0.0' > "$TMP/other/pi"
chmod +x "$TMP/other/pi"
# npm: present (enables the npm.global section); every other package is missing.
printf '%s\n' '#!/bin/sh' 'exit 1' > "$TMP/bin/npm" && chmod +x "$TMP/bin/npm"
PY="$(command -v python3)" && ln -s "$PY" "$TMP/bin/python3" || { echo "FAIL python3 is required"; exit 1; }
HPATH="$TMP/bin:/usr/bin:/bin"
PKG="@earendil-works/pi-coding-agent"

# --- pi_npm_version <path>: 0 version read, 1 unsupported layout, 2 no metadata ---
npm_version() { rc=0; pi_npm_version "$1" || rc=$?; }
npm_version "$TMP/bin/pi"
[ "$rc" = 0 ] && [ "$PI_NPM_VERSION" = 1.6.1 ] \
  && ok "pi_npm_version reads package.json of a global npm install" || bad "pi_npm_version reads package.json of a global npm install"
mkdir -p "$TMP/vp/.vite-plus" "$TMP/proj" "$TMP/pnpm/bin"
make_install "$TMP/vp/.vite-plus/lib/node_modules/$PKG" "$TMP/vp/.vite-plus/bin/pi"
make_install "$TMP/proj/node_modules/$PKG" "$TMP/proj/node_modules/.bin/pi"
make_install "$TMP/pnpm/global/5/node_modules/.pnpm/@earendil-works+pi-coding-agent@1.6.1/node_modules/$PKG" "$TMP/pnpm/bin/pi"
make_install "$TMP/elsewhere/lib/node_modules/$PKG" "$TMP/stray/pi"
for unsupported in "$TMP/vp/.vite-plus/bin/pi" "$TMP/proj/node_modules/.bin/pi" "$TMP/pnpm/bin/pi" \
  "$TMP/stray/pi" "$TMP/other/pi" "$TMP/missing/pi"; do
  npm_version "$unsupported"
  [ "$rc" = 1 ] && [ -n "$PI_NPM_PROBLEM" ] && ok "unsupported layout refused: ${unsupported#"$TMP"/}" \
    || bad "unsupported layout refused: ${unsupported#"$TMP"/} (rc=$rc)"
done
rc=0; (cd "$TMP" && pi_npm_version bin/pi) || rc=$?
[ "$rc" = 1 ] && ok "a relative pi path is never trusted" || bad "a relative pi path is never trusted (rc=$rc)"
set_version "$PKGDIR" 1.6
npm_version "$TMP/bin/pi"
[ "$rc" = 2 ] && ok "an unparsable package.json version is unavailable metadata" || bad "an unparsable package.json version is unavailable metadata (rc=$rc)"
# Status 2 is only for a verified Pi manifest; anything else is not the install (1).
printf '{"name": "evil-package", "version": "1.6.1"}\n' > "$PKGDIR/package.json"
npm_version "$TMP/bin/pi"
[ "$rc" = 1 ] && printf '%s' "$PI_NPM_PROBLEM" | grep -Fq 'evil-package' \
  && ok "a package.json with another package name is not the install (1)" \
  || bad "a package.json with another package name is not the install (1) (rc=$rc)"
printf '[]\n' > "$PKGDIR/package.json"
npm_version "$TMP/bin/pi"
[ "$rc" = 1 ] && ok "a non-object package.json is not the install (1)" || bad "a non-object package.json is not the install (1) (rc=$rc)"
printf '{"name": ' > "$PKGDIR/package.json"
npm_version "$TMP/bin/pi"
[ "$rc" = 1 ] && ok "an unparsable package.json is not the install (1)" || bad "an unparsable package.json is not the install (1) (rc=$rc)"
rm "$PKGDIR/package.json"
npm_version "$TMP/bin/pi"
[ "$rc" = 1 ] && ok "a missing package.json is not the install (1)" || bad "a missing package.json is not the install (1) (rc=$rc)"
set_version "$PKGDIR" 1.6.1
[ ! -e "$LAUNCHES" ] && ok "pi_npm_version never launches Pi" || bad "pi_npm_version never launches Pi"

# A verifier that cannot run (127) or crashes is "could not verify" (3), never
# "verified install, unreadable version" (2) — callers may run Pi only on 0/2.
mkdir -p "$TMP/py127" "$TMP/pycrash" "$TMP/pyempty"
printf '#!/bin/sh\nexit 127\n' > "$TMP/py127/python3"
printf '#!/bin/sh\necho "Traceback (most recent call last):" >&2\nexit 1\n' > "$TMP/pycrash/python3"
printf '#!/bin/sh\nexit 0\n' > "$TMP/pyempty/python3"   # "success" without a version is not proof
chmod +x "$TMP/py127/python3" "$TMP/pycrash/python3" "$TMP/pyempty/python3"
for broken in py127 pycrash pyempty; do
  for target in "$TMP/bin/pi" "$TMP/other/pi"; do
    rc=0; PATH="$TMP/$broken:$PATH" pi_npm_version "$target" || rc=$?
    [ "$rc" = 3 ] && [ -z "$PI_NPM_VERSION" ] && printf '%s' "$PI_NPM_PROBLEM" | grep -Fq 'could not verify' \
      && ok "broken verifier ($broken) on ${target#"$TMP"/} is could-not-verify (3)" \
      || bad "broken verifier ($broken) on ${target#"$TMP"/} is could-not-verify (3) (rc=$rc)"
  done
done
OUT="$(PATH="$TMP/py127:$HPATH" "$ROOT/dot" packages check 2>&1)"
printf '%s\n' "$OUT" | grep -F -- "@earendil-works/pi-coding-agent" | grep -Fq "MISMATCH" \
  && printf '%s\n' "$OUT" | grep -Fq "could not verify" \
  && ok "packages check: a broken verifier is a mismatch, not ok" || bad "packages check: a broken verifier is a mismatch, not ok"
OUT=""

# --- ./dot packages check / pi doctor ------------------------------------------------
packages() { set_version "$PKGDIR" "$1"; OUT="$(PATH="${2:-$HPATH}" "$ROOT/dot" packages check 2>&1)"; }
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
packages 99.0.0 "$TMP/other:$HPATH"
pi_line | grep -Eq "^  MISMATCH $PKG.*not a global npm install" \
  && ok "packages check: a non-npm-layout Pi is a mismatch even when new enough" \
  || bad "packages check: a non-npm-layout Pi is a mismatch even when new enough"
packages 1.6
pi_line | grep -Eq "^  MISMATCH $PKG.*version unavailable" \
  && ok "packages check: unreadable Pi metadata is a mismatch" || bad "packages check: unreadable Pi metadata is a mismatch"

doctor() { set_version "$PKGDIR" "$1"; OUT="$(PATH="${2:-$HPATH}" "$ROOT/dot" pi doctor 2>&1)"; }
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
printf '%s\n' "$OUT" | grep -Fq "WARN Pi at $TMP/other/pi is not the required npm package layout" \
  && ok "pi doctor: a non-npm-layout Pi warns" || bad "pi doctor: a non-npm-layout Pi warns"
[ ! -e "$LAUNCHES" ] && ok "packages check and pi doctor never launch Pi" \
  || { OUT="$(cat "$LAUNCHES")"; bad "packages check and pi doctor never launch Pi"; }

printf '\n== pi-version tests: %d pass, %d fail ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
