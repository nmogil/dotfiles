#!/usr/bin/env bash
# Tests for scripts/setup-rexboard.sh (./dot rexboard). Hermetic: a temp HOME,
# a copy of the installer beside a fixture release.env, a fixture release
# served over file://, and stub uname/brew on a PATH without the real tools.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; failn=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; failn=$((failn+1)); [ -f "$OUT" ] && sed 's/^/       /' "$OUT"; }
die() { echo "fixture error: $*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

OUT="$TMP/out"
REPO="$TMP/repo"; STUB="$TMP/stub"; REL="$TMP/release"
mkdir -p "$REPO/scripts" "$REPO/config/rexboard" "$STUB" "$REL" || die mkdir
cp "$ROOT/scripts/setup-rexboard.sh" "$REPO/scripts/" || die "copy installer"

# Fixture release: <archive>/<dir>/rexboard, as upstream packages it.
ARCHIVE=rexboard-v9.9.9-x86_64-unknown-linux-gnu.tar.gz
mkdir -p "$TMP/build/rexboard-v9.9.9-x86_64-unknown-linux-gnu" || die build
printf '#!/bin/sh\necho "rexboard 9.9.9"\n' > "$TMP/build/rexboard-v9.9.9-x86_64-unknown-linux-gnu/rexboard"
chmod 755 "$TMP/build/rexboard-v9.9.9-x86_64-unknown-linux-gnu/rexboard"
echo MIT > "$TMP/build/rexboard-v9.9.9-x86_64-unknown-linux-gnu/LICENSE"
(cd "$TMP/build" && tar -czf "$REL/$ARCHIVE" rexboard-v9.9.9-x86_64-unknown-linux-gnu) || die tar
ARCHIVE_SHA="$(sha "$REL/$ARCHIVE")"
BINARY_SHA="$(sha "$TMP/build/rexboard-v9.9.9-x86_64-unknown-linux-gnu/rexboard")"

write_pins() {  # write_pins [archive-sha] [binary-sha]
  cat > "$REPO/config/rexboard/release.env" <<EOF
# fixture
REXBOARD_VERSION=9.9.9
REXBOARD_RELEASE_URL=file://$REL
REXBOARD_LINUX_X86_64_ARCHIVE=$ARCHIVE
REXBOARD_LINUX_X86_64_ARCHIVE_SHA256=${1:-$ARCHIVE_SHA}
REXBOARD_LINUX_X86_64_BINARY_SHA256=${2:-$BINARY_SHA}
REXBOARD_BREW_FORMULA=vanducng/tap/rexboard
EOF
}

cat > "$STUB/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in -m) echo "${STUB_ARCH:-x86_64}" ;; *) echo "${STUB_OS:-Linux}" ;; esac
EOF
# brew stub: STUB_BREW_HAS=<version> means the formula is installed.
cat > "$STUB/brew" <<'EOF'
#!/bin/sh
echo "brew $*" >> "$STUB_LOG"
case "$*" in
  "list --versions rexboard") [ -n "${STUB_BREW_HAS:-}" ] && echo "rexboard $STUB_BREW_HAS" ;;
  "install vanducng/tap/rexboard") exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$STUB/uname" "$STUB/brew"
NOBREW="$TMP/stub-nobrew"; mkdir -p "$NOBREW"; cp "$STUB/uname" "$NOBREW/"

HOMEDIR="$TMP/home"
DST="$HOMEDIR/.local/bin/rexboard"
fresh() { chmod -R u+w "$HOMEDIR" 2>/dev/null; rm -rf "$HOMEDIR"; mkdir -p "$HOMEDIR"; : > "$TMP/calls"; write_pins; }
# run <args...>: the installer under a PATH with only the stubs and /usr/bin:/bin.
run() {
  (cd "$TMP" && env -i HOME="$HOMEDIR" PATH="${STUB_PATH:-$STUB}:/usr/bin:/bin" STUB_LOG="$TMP/calls" \
    STUB_OS="${STUB_OS:-Linux}" STUB_ARCH="${STUB_ARCH:-x86_64}" STUB_BREW_HAS="${STUB_BREW_HAS:-}" \
    bash "$REPO/scripts/setup-rexboard.sh" "$@") > "$OUT" 2>&1
  RC=$?
}
has() { grep -Fq -- "$1" "$OUT"; }
home_files() { (cd "$HOMEDIR" && find . -mindepth 1 | LC_ALL=C sort); }

# --- usage -------------------------------------------------------------------
fresh; run --bogus
[ "$RC" = 2 ] && has "usage" && ok "unknown option exits 2" || bad "unknown option exits 2"
fresh; run --help
[ "$RC" = 0 ] && has "usage" && ok "--help prints usage" || bad "--help prints usage"

# --- ./dot passes every flag through ----------------------------------------
"$ROOT/dot" rexboard --help > "$OUT" 2>&1; RC=$?
[ "$RC" = 0 ] && has "usage: ./dot rexboard" && ok "./dot rexboard --help reaches the installer with its flag" \
  || bad "./dot rexboard --help reaches the installer with its flag"
"$ROOT/dot" rexboard --bogus > "$OUT" 2>&1; RC=$?
[ "$RC" = 2 ] && ok "./dot rexboard passes unknown flags through (exit 2)" || bad "./dot rexboard passes unknown flags through (exit 2)"

# --- Linux: fresh machine ------------------------------------------------------
fresh; run
[ "$RC" = 0 ] && has "would install rexboard 9.9.9" && [ -z "$(home_files)" ] \
  && ok "Linux dry-run (default) reports the install and writes nothing" \
  || bad "Linux dry-run (default) reports the install and writes nothing"
fresh; run --check
[ "$RC" = 3 ] && has "not installed" && [ -z "$(home_files)" ] \
  && ok "Linux --check exits 3 when rexboard is not installed" \
  || bad "Linux --check exits 3 when rexboard is not installed"
fresh; run --apply
if [ "$RC" = 0 ] && has "installed rexboard 9.9.9" && [ -f "$DST" ] && [ ! -L "$DST" ] && [ -x "$DST" ] \
  && [ "$(sha "$DST")" = "$BINARY_SHA" ] && [ "$(home_files)" = "./.local
./.local/bin
./.local/bin/rexboard" ]; then
  ok "Linux --apply installs the pinned binary (and nothing else) to ~/.local/bin"
else bad "Linux --apply installs the pinned binary (and nothing else) to ~/.local/bin"; fi
run --check
[ "$RC" = 0 ] && has "matches the pinned 9.9.9 build" && ok "Linux --check passes after install" \
  || bad "Linux --check passes after install"
mv "$REL/$ARCHIVE" "$REL/away" || die mv
run --apply
[ "$RC" = 0 ] && has "already installed" && ok "Linux --apply is a no-op (no download) when the binary matches" \
  || bad "Linux --apply is a no-op (no download) when the binary matches"
run --dry-run
[ "$RC" = 0 ] && has "already installed" && ok "Linux dry-run reports an existing match" || bad "Linux dry-run reports an existing match"
mv "$REL/away" "$REL/$ARCHIVE" || die mv

# --- Linux: verification failures install nothing -----------------------------------
fresh; write_pins "$(printf '0%.0s' $(seq 1 64))"
run --apply
[ "$RC" = 1 ] && has "checksum mismatch" && [ ! -e "$DST" ] && [ -z "$(ls -A "$HOMEDIR/.local/bin" 2>/dev/null)" ] \
  && ok "an archive checksum mismatch installs nothing" || bad "an archive checksum mismatch installs nothing"
fresh; write_pins "" "$(printf 'a%.0s' $(seq 1 64))"
run --apply
[ "$RC" = 1 ] && has "binary checksum mismatch" && [ ! -e "$DST" ] && [ -z "$(ls -A "$HOMEDIR/.local/bin" 2>/dev/null)" ] \
  && ok "a binary checksum mismatch installs nothing" || bad "a binary checksum mismatch installs nothing"
fresh; write_pins "not-a-hash"
run --apply
[ "$RC" = 1 ] && has "release.env" && [ ! -e "$DST" ] && ok "a malformed pin is refused before downloading" \
  || bad "a malformed pin is refused before downloading"
fresh; sed -i.bak '/^REXBOARD_LINUX_X86_64_BINARY_SHA256=/d' "$REPO/config/rexboard/release.env"; rm -f "$REPO/config/rexboard/release.env.bak"
run --check
[ "$RC" = 1 ] && has "REXBOARD_LINUX_X86_64_BINARY_SHA256" && ok "a missing pin fails --check" || bad "a missing pin fails --check"
fresh; printf 'REXBOARD_VERSION=$(touch %s/pwned)\n' "$TMP" > "$REPO/config/rexboard/release.env"
run --check
[ "$RC" = 1 ] && [ ! -e "$TMP/pwned" ] && ok "release.env is parsed as data, never executed" \
  || bad "release.env is parsed as data, never executed"

# --- Linux: an existing binary that is not the pinned build ----------------------------
fresh; mkdir -p "$HOMEDIR/.local/bin"; printf '#!/bin/sh\necho "rexboard 0.1.0"\n' > "$DST"; chmod 755 "$DST"
before="$(sha "$DST")"
run --check
[ "$RC" = 1 ] && has "differs from the pinned 9.9.9 build" && ok "Linux --check reports a differing binary" \
  || bad "Linux --check reports a differing binary"
run --apply
[ "$RC" = 1 ] && has "--force" && [ "$(sha "$DST")" = "$before" ] \
  && ok "Linux --apply leaves a differing binary alone without --force" \
  || bad "Linux --apply leaves a differing binary alone without --force"
run --dry-run
[ "$RC" = 0 ] && has "differs" && [ "$(sha "$DST")" = "$before" ] && ok "Linux dry-run reports the difference" \
  || bad "Linux dry-run reports the difference"
run --apply --force
backup="$(find "$HOMEDIR/.local/state/dotfiles/rexboard-backups" -type f -name rexboard 2>/dev/null | head -1)"
if [ "$RC" = 0 ] && [ "$(sha "$DST")" = "$BINARY_SHA" ] && [ -n "$backup" ] && [ "$(sha "$backup")" = "$before" ] \
  && has "backed up"; then
  ok "Linux --apply --force backs up the differing binary, then installs the pin"
else bad "Linux --apply --force backs up the differing binary, then installs the pin"; fi
fresh; mkdir -p "$HOMEDIR/.local/bin" "$TMP/elsewhere"; printf 'x\n' > "$TMP/elsewhere/target"
ln -s "$TMP/elsewhere/target" "$DST"
run --apply --force
[ "$RC" = 1 ] && has "symlink" && [ -L "$DST" ] && [ "$(cat "$TMP/elsewhere/target")" = x ] \
  && ok "a symlink at ~/.local/bin/rexboard is refused, even with --force" \
  || bad "a symlink at ~/.local/bin/rexboard is refused, even with --force"
fresh; run --force
[ "$RC" = 2 ] && ok "--force needs --apply" || bad "--force needs --apply"

# --- Linux: no pinned build for this architecture -------------------------------------
fresh; STUB_ARCH=aarch64 run --apply
[ "$RC" = 1 ] && has "no pinned rexboard build for Linux aarch64" && [ -z "$(home_files)" ] \
  && ok "Linux on another architecture is refused" || bad "Linux on another architecture is refused"

# --- macOS: Homebrew owns the install --------------------------------------------------
fresh; STUB_OS=Darwin STUB_ARCH=arm64 STUB_BREW_HAS=0.37.1 run --check
[ "$RC" = 0 ] && has "rexboard 0.37.1 installed with Homebrew" \
  && ok "macOS --check passes for a Homebrew install of any version (Homebrew owns updates)" \
  || bad "macOS --check passes for a Homebrew install of any version (Homebrew owns updates)"
STUB_OS=Darwin STUB_ARCH=arm64 STUB_BREW_HAS=0.37.1 run --apply
[ "$RC" = 0 ] && has "already installed" && ! grep -q '^brew install' "$TMP/calls" && ! grep -q 'upgrade\|uninstall\|reinstall' "$TMP/calls" \
  && ok "macOS --apply never reinstalls, upgrades, or removes an existing Homebrew install" \
  || bad "macOS --apply never reinstalls, upgrades, or removes an existing Homebrew install"
fresh; STUB_OS=Darwin STUB_ARCH=arm64 run --check
[ "$RC" = 3 ] && has "not installed" && ok "macOS --check exits 3 when it is not installed" \
  || bad "macOS --check exits 3 when it is not installed"
STUB_OS=Darwin STUB_ARCH=arm64 run
[ "$RC" = 0 ] && has "would run: brew install vanducng/tap/rexboard" && ! grep -q '^brew install' "$TMP/calls" \
  && ok "macOS dry-run only reports the brew install" || bad "macOS dry-run only reports the brew install"
STUB_OS=Darwin STUB_ARCH=arm64 run --apply
[ "$RC" = 0 ] && grep -Fxq 'brew install vanducng/tap/rexboard' "$TMP/calls" && [ -z "$(home_files)" ] \
  && ok "macOS --apply installs with Homebrew (nothing in ~/.local/bin)" \
  || bad "macOS --apply installs with Homebrew (nothing in ~/.local/bin)"
fresh; mkdir -p "$TMP/otherbin"; printf '#!/bin/sh\necho rexboard 0.1.0\n' > "$TMP/otherbin/rexboard"; chmod 755 "$TMP/otherbin/rexboard"
STUB_PATH="$STUB:$TMP/otherbin" STUB_OS=Darwin STUB_ARCH=arm64 run --apply
[ "$RC" = 1 ] && has "not from Homebrew" && ! grep -q '^brew install' "$TMP/calls" \
  && ok "macOS --apply refuses when a non-Homebrew rexboard is already on PATH" \
  || bad "macOS --apply refuses when a non-Homebrew rexboard is already on PATH"
STUB_PATH="$STUB:$TMP/otherbin" STUB_OS=Darwin STUB_ARCH=arm64 run --check
[ "$RC" = 1 ] && has "not from Homebrew" && ok "macOS --check flags a non-Homebrew rexboard" \
  || bad "macOS --check flags a non-Homebrew rexboard"
fresh; STUB_PATH="$NOBREW" STUB_OS=Darwin STUB_ARCH=arm64 run --apply
[ "$RC" = 1 ] && has "Homebrew is required" && ok "macOS --apply without Homebrew fails clearly" \
  || bad "macOS --apply without Homebrew fails clearly"

# --- the real pin file is well formed -----------------------------------------------
grep -Eq '^REXBOARD_LINUX_X86_64_ARCHIVE_SHA256=[0-9a-f]{64}$' "$ROOT/config/rexboard/release.env" \
  && grep -Eq '^REXBOARD_LINUX_X86_64_BINARY_SHA256=[0-9a-f]{64}$' "$ROOT/config/rexboard/release.env" \
  && grep -Eq '^REXBOARD_RELEASE_URL=https://github\.com/vanducng/rexboard/releases/download/v[0-9.]+$' "$ROOT/config/rexboard/release.env" \
  && ok "the committed release.env pins https URLs and full sha256 checksums" \
  || bad "the committed release.env pins https URLs and full sha256 checksums"

echo
echo "rexboard tests: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
