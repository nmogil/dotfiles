#!/usr/bin/env bash
# Tests for scripts/setup-rexume.sh (./dot rexume). Hermetic: a temp HOME, a
# copy of the installer and its library beside a fixture release.pins, a
# fixture release served over file://, and stub uname/brew/gh/rex/systemctl/
# launchctl on a PATH without the real tools. The fixture rexume (in the
# release and in the fake Homebrew keg) records every run and the environment
# `rexume install` gets, and mimics what install writes.
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
mkdir -p "$REPO/scripts/lib" "$REPO/config/rexume" "$STUB" "$REL" || die mkdir
cp "$ROOT/scripts/setup-rexume.sh" "$REPO/scripts/" || die "copy installer"
cp "$ROOT/scripts/lib/pinned-release.sh" "$REPO/scripts/lib/" || die "copy library"

# The fixture rexume. Only `install` and `status` are expected; anything else
# is recorded as unexpected.
REXUME_SRC="$TMP/rexume-src"
cat > "$REXUME_SRC" <<'EOF'
#!/bin/sh
echo "rexume $*" >> "$STUB_LOG"
case "$*" in
  install)
    env | LC_ALL=C sort > "$STUB_TMP/install-env"
    if [ -n "${STUB_REXUME_INSTALL_FAIL:-}" ]; then echo "rexume: could not reach the user manager" >&2; exit 1; fi
    agent="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
    pi=skipped; note='"`~/.pi/agent` does not exist"'
    if [ -d "$agent" ]; then
      mkdir -p "$agent/extensions" && printf '// Written by `rexume install`\n' > "$agent/extensions/rexume.ts"
      pi=created; note=null
    fi
    : > "$STUB_TMP/daemon-active"
    if [ "$(uname -s)" = Darwin ]; then
      mkdir -p "$HOME/Library/LaunchAgents" && : > "$HOME/Library/LaunchAgents/io.github.entwining.rexume.plist"
      job='"launch_agent": "created", "launch_agent_note": null, "launch_agent_label": "io.github.entwining.rexume"'
    else
      mkdir -p "$HOME/.config/systemd/user" && : > "$HOME/.config/systemd/user/rexume.service"
      job='"systemd_unit": "created", "systemd_unit_note": null, "systemd_unit_name": "rexume.service"'
    fi
    printf '{ "version": 1, "claude_hook": "skipped", "claude_hook_note": "`~/.claude` does not exist",\n  "pi_extension": "%s", "pi_extension_note": %s, "omp_extension": "skipped", "omp_extension_note": "`~/.omp/agent` does not exist",\n  %s }\n' "$pi" "$note" "$job"
    ;;
  status)
    printf '{"version":3,"restores":[],"undelivered_notices":[],"epoch_error":null,"claude_hooks_missing":%s}\n' "${STUB_HOOKS_MISSING:-[]}"
    ;;
  *) echo "rexume $*" >> "$STUB_UNEXPECTED"; exit 1 ;;
esac
EOF
chmod 755 "$REXUME_SRC"

# Fixture release, packaged as upstream does: <dir>/bin/rexume.
ARCHIVE=rexume-9.9.9-x86_64-unknown-linux-musl.tar.gz
PKG=rexume-9.9.9-x86_64-unknown-linux-musl
mkdir -p "$TMP/build/$PKG/bin" || die build
cp "$REXUME_SRC" "$TMP/build/$PKG/bin/rexume"; echo MIT > "$TMP/build/$PKG/LICENSE"
(cd "$TMP/build" && tar -czf "$REL/$ARCHIVE" "$PKG") || die tar
ARCHIVE_SHA="$(sha "$REL/$ARCHIVE")"
BINARY_SHA="$(sha "$TMP/build/$PKG/bin/rexume")"
WORKFLOW=Entwining/rexume/.github/workflows/publish.yml

write_pins() {  # write_pins [archive-sha] [binary-sha] [member]
  cat > "$REPO/config/rexume/release.pins" <<EOF
# fixture
REXUME_VERSION=9.9.9
REXUME_RELEASE_URL=file://$REL
REXUME_LINUX_X86_64_ARCHIVE=$ARCHIVE
REXUME_LINUX_X86_64_ARCHIVE_SHA256=${1:-$ARCHIVE_SHA}
REXUME_LINUX_X86_64_BINARY_MEMBER=${3:-$PKG/bin/rexume}
REXUME_LINUX_X86_64_BINARY_SHA256=${2:-$BINARY_SHA}
REXUME_ATTESTATION_REPO=Entwining/rexume
REXUME_ATTESTATION_SIGNER_WORKFLOW=$WORKFLOW
REXUME_BREW_FORMULA=entwining/tap/rexume
EOF
}

cat > "$STUB/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in -m) echo "${STUB_ARCH:-x86_64}" ;; *) echo "${STUB_OS:-Linux}" ;; esac
EOF
# rex: a server that has two sessions, the second with one pane. STUB_REX picks
# ok (preview.23+: a block ID works as a session), old (refuses it), noblocks,
# or down. Every call must pass --autostart=false; anything but the read-only
# listings is unexpected.
cat > "$STUB/rex" <<'EOF'
#!/bin/sh
echo "rex $*" >> "$STUB_LOG"
if [ "${1:-}" = --autostart=false ]; then shift; else echo "rex without --autostart=false: $*" >> "$STUB_UNEXPECTED"; fi
mode="${STUB_REX:-ok}"
case "$*" in
  "ls --json")
    [ "$mode" != down ] || { echo "Error: no server" >&2; exit 1; }
    printf '{\n  "sessions": [\n    {\n      "session_id": "session:01a2-0001",\n      "label": "a"\n    },\n    {"session_id": "session:01a2-0002", "label": "b"}\n  ]\n}\n' ;;
  "block ls --json -s session:01a2-0001") printf '{\n  "blocks": []\n}\n' ;;
  "block ls --json -s session:01a2-0002")
    if [ "$mode" = noblocks ]; then printf '{"blocks": []}\n'
    else printf '{\n  "blocks": [\n    {\n      "block_id": "block:01a2-00b2",\n      "label": "shell"\n    }\n  ]\n}\n'; fi ;;
  "block ls --json -s block:01a2-00b2")
    if [ "$mode" = old ]; then
      echo 'Error: session target "block:01a2-00b2" not found: "block:01a2-00b2" is a block ID, not a session' >&2; exit 3
    fi
    printf '{"blocks": [{"block_id": "block:01a2-00b2"}]}\n' ;;
  *) echo "rex $*" >> "$STUB_UNEXPECTED"; exit 1 ;;
esac
EOF
cat > "$STUB/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >> "$STUB_LOG"
case "${1:-} ${2:-}" in
  "attestation verify")
    if command -v sha256sum >/dev/null 2>&1; then s="$(sha256sum "$3")"; else s="$(shasum -a 256 "$3")"; fi
    echo "gh verified-sha ${s%% *}" >> "$STUB_LOG"
    [ -z "${STUB_GH_FAIL:-}" ] || { echo "Error: verifying with issuer \"sigstore.dev\"" >&2; exit 1; }
    ;;
  *) echo "gh $*" >> "$STUB_UNEXPECTED"; exit 1 ;;
esac
EOF
cat > "$STUB/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$STUB_LOG"
case "$*" in
  "--user is-active --quiet rexume") [ -e "$STUB_TMP/daemon-active" ] ;;
  *) echo "systemctl $*" >> "$STUB_UNEXPECTED"; exit 1 ;;
esac
EOF
cat > "$STUB/launchctl" <<'EOF'
#!/bin/sh
echo "launchctl $*" >> "$STUB_LOG"
case "$*" in
  "print gui/$(id -u)/io.github.entwining.rexume")
    [ -e "$STUB_TMP/daemon-active" ] || { echo 'Could not find service "io.github.entwining.rexume" in domain for user gui' >&2; exit 113; }
    printf 'gui/%s/io.github.entwining.rexume = {\n\tactive count = 1\n\tstate = %s\n}\n' "$(id -u)" "${STUB_LAUNCHD_STATE:-running}" ;;
  *) echo "launchctl $*" >> "$STUB_UNEXPECTED"; exit 1 ;;
esac
EOF
# brew: `--cellar` prints STUB_CELLAR; `install entwining/tap/rexume` makes a keg
# linked onto STUB_BREWBIN, as Homebrew does. Anything else is unexpected.
cat > "$STUB/brew" <<'EOF'
#!/bin/sh
echo "brew $*" >> "$STUB_LOG"
case "$*" in
  "--cellar") echo "$STUB_CELLAR" ;;
  "install entwining/tap/rexume")
    [ -z "${STUB_BREW_INSTALL_FAIL:-}" ] || exit 1
    mkdir -p "$STUB_CELLAR/rexume/0.1.28/bin" "$STUB_BREWBIN" && cp "$STUB_KEG_SRC" "$STUB_CELLAR/rexume/0.1.28/bin/rexume" \
      && ln -sf "$STUB_CELLAR/rexume/0.1.28/bin/rexume" "$STUB_BREWBIN/rexume" ;;
  *) echo "brew $*" >> "$STUB_UNEXPECTED"; exit 1 ;;
esac
EOF
# curl: logged, then the real one (the fixture release is served over file://).
cat > "$STUB/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$STUB_LOG"
exec /usr/bin/curl "$@"
EOF
chmod 755 "$STUB"/*
NOGH="$TMP/stub-nogh"; mkdir -p "$NOGH"; cp -p "$STUB"/* "$NOGH/"; rm -f "$NOGH/gh"

HOMEDIR="$TMP/home"
DST="$HOMEDIR/.local/bin/rexume"
CELLAR="$TMP/cellar"; BREWBIN="$TMP/brewbin"
UNEXPECTED="$TMP/unexpected"; : > "$UNEXPECTED"
PERSONAL_EXT="$HOMEDIR/.pi/agent/extensions/rexume.ts"
WORK_EXT="$HOMEDIR/.pi/agent-work/extensions/rexume.ts"

# fresh [shared]: a new HOME with a personal Pi profile and a work profile whose
# extensions directory is its own, or, with `shared`, a link to the personal one
# (the layout setup-pi-profiles.sh makes).
fresh() {
  chmod -R u+w "$HOMEDIR" 2>/dev/null
  rm -rf "$HOMEDIR" "$CELLAR" "$BREWBIN" "$TMP/daemon-active" "$TMP/install-env"
  mkdir -p "$HOMEDIR/.pi/agent/extensions" "$HOMEDIR/.pi/agent-work" || die home
  if [ "${1:-}" = shared ]; then ln -s "$HOMEDIR/.pi/agent/extensions" "$HOMEDIR/.pi/agent-work/extensions"
  else mkdir -p "$HOMEDIR/.pi/agent-work/extensions"; fi
  : > "$TMP/calls"; write_pins
}
# brew_has <version>: a fake Homebrew keg of the fixture rexume, linked onto PATH.
brew_has() {
  mkdir -p "$CELLAR/rexume/$1/bin" "$BREWBIN" || die cellar
  cp "$REXUME_SRC" "$CELLAR/rexume/$1/bin/rexume"
  ln -sf "../cellar/rexume/$1/bin/rexume" "$BREWBIN/rexume" || die link
}
# run <args...>: the installer as if started from a `pi-work` shell
# (PI_CODING_AGENT_DIR set to the work profile), on a PATH of stubs + /usr/bin:/bin.
run() {
  local xdg="XDG_RUNTIME_DIR=$TMP/run"
  [ -z "${NO_XDG:-}" ] || xdg="NO_XDG=1"
  (cd "$TMP" && env -i HOME="$HOMEDIR" PATH="${STUB_PATH:-$STUB}:/usr/bin:/bin" "$xdg" \
    PI_CODING_AGENT_DIR="$HOMEDIR/.pi/agent-work" \
    STUB_LOG="$TMP/calls" STUB_TMP="$TMP" STUB_UNEXPECTED="$UNEXPECTED" \
    STUB_OS="${STUB_OS:-Linux}" STUB_ARCH="${STUB_ARCH:-x86_64}" STUB_CELLAR="$CELLAR" STUB_BREWBIN="$BREWBIN" \
    STUB_KEG_SRC="$REXUME_SRC" STUB_REX="${STUB_REX:-ok}" STUB_GH_FAIL="${STUB_GH_FAIL:-}" \
    STUB_REXUME_INSTALL_FAIL="${STUB_REXUME_INSTALL_FAIL:-}" STUB_HOOKS_MISSING="${STUB_HOOKS_MISSING:-[]}" \
    STUB_LAUNCHD_STATE="${STUB_LAUNCHD_STATE:-running}" STUB_BREW_INSTALL_FAIL="${STUB_BREW_INSTALL_FAIL:-}" \
    "$BASH" "$REPO/scripts/setup-rexume.sh" "$@") > "$OUT" 2>&1
  RC=$?
}
mac() { STUB_PATH="$STUB:$BREWBIN" STUB_OS=Darwin STUB_ARCH=arm64 run "$@"; }
has() { grep -Fq -- "$1" "$OUT"; }
called() { grep -Fq -- "$1" "$TMP/calls"; }
called_x() { grep -Fxq -- "$1" "$TMP/calls"; }
# snapshot: every path under HOME with its type and content hash.
snapshot() {
  (cd "$HOMEDIR" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then echo "L $p $(readlink "$p")"; elif [ -f "$p" ]; then echo "F $p $(sha "$p")"; else echo "D $p"; fi
  done)
}
installed() { called_x "rexume install"; }
# The rexume runs during a check: only `rexume status`.
only_status() { ! grep '^rexume ' "$TMP/calls" | grep -vxq 'rexume status'; }

# --- usage and ./dot ------------------------------------------------------------
fresh; run --bogus
if [ "$RC" = 2 ] && has usage; then
  ok "unknown option exits 2"; else bad "unknown option exits 2"; fi
fresh; run --help
if [ "$RC" = 0 ] && has "usage: ./dot rexume"; then
  ok "--help prints usage"; else bad "--help prints usage"; fi
fresh; run --force
if [ "$RC" = 2 ]; then
  ok "--force needs --apply"; else bad "--force needs --apply"; fi
"$ROOT/dot" rexume --help > "$OUT" 2>&1; RC=$?
if [ "$RC" = 0 ] && has "usage: ./dot rexume"; then
  ok "./dot rexume --help reaches the installer with its flag"; else bad "./dot rexume --help reaches the installer with its flag"; fi
"$ROOT/dot" rexume --apply --bogus > "$OUT" 2>&1; RC=$?
if [ "$RC" = 2 ] && has "usage: ./dot rexume"; then
  ok "./dot rexume passes every argument through (exit 2)"; else bad "./dot rexume passes every argument through (exit 2)"; fi

# --- Linux: dry-run and check on a fresh machine ------------------------------------
fresh; before="$(snapshot)"; run
if [ "$RC" = 0 ] && has "would install rexume 9.9.9" && has "attestation" && has "would run: env -u PI_CODING_AGENT_DIR" && has "rexume install"; then
  ok "Linux dry-run (default) reports the plan"; else bad "Linux dry-run (default) reports the plan"; fi
if [ "$(snapshot)" = "$before" ] && [ ! -e "$TMP/daemon-active" ]; then
  ok "Linux dry-run writes nothing"; else bad "Linux dry-run writes nothing"; fi
if ! called "gh " && ! called "rex " && ! called "rexume " && ! called "curl "; then
  ok "Linux dry-run does no network and runs neither gh, rex, nor rexume"; else bad "Linux dry-run does no network and runs neither gh, rex, nor rexume"; fi
fresh; before="$(snapshot)"; run --check
if [ "$RC" = 3 ] && has "not installed"; then
  ok "Linux --check exits 3 when rexume is not installed at all"; else bad "Linux --check exits 3 when rexume is not installed at all"; fi
if [ "$(snapshot)" = "$before" ]; then
  ok "Linux --check writes nothing"; else bad "Linux --check writes nothing"; fi

# --- Linux: install --------------------------------------------------------------------
fresh; run --apply
if [ "$RC" = 0 ] && [ -f "$DST" ] && [ ! -L "$DST" ] && [ -x "$DST" ] && [ "$(sha "$DST")" = "$BINARY_SHA" ] && called "curl "; then
  ok "Linux --apply installs the pinned binary"; else bad "Linux --apply installs the pinned binary"; fi
if grep -Eq "^gh attestation verify .*/$ARCHIVE --repo Entwining/rexume --signer-workflow $WORKFLOW\$" "$TMP/calls" && called_x "gh verified-sha $ARCHIVE_SHA"; then
  ok "Linux --apply verifies the GitHub attestation of the pinned archive with the pinned signer workflow"; else bad "Linux --apply verifies the GitHub attestation of the pinned archive with the pinned signer workflow"; fi
if called_x "rex --autostart=false ls --json" && called_x "rex --autostart=false block ls --json -s block:01a2-00b2" && [ "$(grep -n "block:01a2-00b2" "$TMP/calls" | head -1 | cut -d: -f1)" -lt "$(grep -nx "rexume install" "$TMP/calls" | cut -d: -f1)" ]; then
  ok "Linux --apply probes the Rex server with a block ID before rexume install"; else bad "Linux --apply probes the Rex server with a block ID before rexume install"; fi
if [ "$(grep -cx "rexume install" "$TMP/calls")" = 1 ]; then
  ok "Linux --apply runs rexume install once"; else bad "Linux --apply runs rexume install once"; fi
if [ -f "$TMP/install-env" ] && ! grep -q "^PI_CODING_AGENT_DIR=" "$TMP/install-env"; then
  ok "rexume install runs without PI_CODING_AGENT_DIR (set in the caller's shell)"; else bad "rexume install runs without PI_CODING_AGENT_DIR (set in the caller's shell)"; fi
if [ -f "$PERSONAL_EXT" ] && [ ! -e "$WORK_EXT" ]; then
  ok "the work profile gets no rexume extension; the personal profile does"; else bad "the work profile gets no rexume extension; the personal profile does"; fi
if grep -q "^PATH=$HOMEDIR/.local/bin:" "$TMP/install-env"; then
  ok "rexume install (and so the daemon) gets ~/.local/bin on PATH"; else bad "rexume install (and so the daemon) gets ~/.local/bin on PATH"; fi
if has "pi_extension=created" && has "systemd_unit=created" && ! has "\"version\""; then
  ok "Linux --apply prints rexume's JSON summary condensed"; else bad "Linux --apply prints rexume's JSON summary condensed"; fi
if has "rexume is installed"; then
  ok "Linux --apply ends with a passing check"; else bad "Linux --apply ends with a passing check"; fi
run --check
if [ "$RC" = 0 ] && has "matches the pinned 9.9.9 build" && has "rexume is installed"; then
  ok "Linux --check passes after install"; else bad "Linux --check passes after install"; fi
: > "$TMP/calls"; run --check
if only_status && called_x "rexume status" && called_x "systemctl --user is-active --quiet rexume" && ! called "rex "; then
  ok "Linux --check runs rexume only for the read-only status, and only the is-active query of systemd"; else bad "Linux --check runs rexume only for the read-only status, and only the is-active query of systemd"; fi
mv "$REL/$ARCHIVE" "$REL/away" || die mv
: > "$TMP/calls"; run --apply
if [ "$RC" = 0 ] && has "already installed" && ! called "curl " && ! called "gh " && installed; then
  ok "Linux --apply again: no download, no reinstall of the binary, rexume install reruns"; else bad "Linux --apply again: no download, no reinstall of the binary, rexume install reruns"; fi
mv "$REL/away" "$REL/$ARCHIVE" || die mv
before="$(snapshot)"; : > "$TMP/calls"; run --dry-run
if [ "$RC" = 0 ] && [ "$(snapshot)" = "$before" ] && ! called "rexume " && ! called "rex " && ! called "gh "; then
  ok "Linux dry-run on an installed machine writes nothing and runs nothing"; else bad "Linux dry-run on an installed machine writes nothing and runs nothing"; fi

# --- Linux: the attestation is required -------------------------------------------------
fresh; STUB_PATH="$NOGH" run --apply
if [ "$RC" = 1 ] && has "gh" && [ ! -e "$DST" ] && [ -z "$(ls -A "$HOMEDIR/.local/bin" 2>/dev/null)" ] && ! installed; then
  ok "Linux --apply without gh installs nothing"; else bad "Linux --apply without gh installs nothing"; fi
fresh; STUB_GH_FAIL=1 run --apply
if [ "$RC" = 1 ] && has "attestation" && [ ! -e "$DST" ] && [ -z "$(ls -A "$HOMEDIR/.local/bin" 2>/dev/null)" ] && ! installed; then
  ok "Linux --apply with a failing attestation installs nothing"; else bad "Linux --apply with a failing attestation installs nothing"; fi
fresh; write_pins "$(printf '0%.0s' $(seq 1 64))"; run --apply
if [ "$RC" = 1 ] && has "checksum mismatch" && [ ! -e "$DST" ] && ! called "gh " && ! installed; then
  ok "an archive checksum mismatch installs nothing (and is caught before the attestation)"; else bad "an archive checksum mismatch installs nothing (and is caught before the attestation)"; fi
fresh; write_pins "" "$(printf 'a%.0s' $(seq 1 64))"; run --apply
if [ "$RC" = 1 ] && has "binary checksum mismatch" && [ ! -e "$DST" ] && ! installed; then
  ok "a binary checksum mismatch installs nothing"; else bad "a binary checksum mismatch installs nothing"; fi
fresh; write_pins "" "" "../evil/bin/rexume"; run --apply
if [ "$RC" = 1 ] && has "REXUME_LINUX_X86_64_BINARY_MEMBER" && [ ! -e "$DST" ]; then
  ok "a binary member outside the pinned archive's directory is refused"; else bad "a binary member outside the pinned archive's directory is refused"; fi
fresh; printf 'REXUME_VERSION=$(touch %s/pwned)\n' "$TMP" > "$REPO/config/rexume/release.pins"; run --check
if [ "$RC" = 1 ] && [ ! -e "$TMP/pwned" ]; then
  ok "release.pins is parsed as data, never executed"; else bad "release.pins is parsed as data, never executed"; fi

# --- the Rex server must take a block ID where a session goes --------------------------------
fresh; STUB_REX=old run --apply
if [ "$RC" = 1 ] && has "preview.23" && has "upgrade" && ! installed && [ ! -e "$DST" ]; then
  ok "an older Rex server (block ID refused) stops before anything is installed"; else bad "an older Rex server (block ID refused) stops before anything is installed"; fi
fresh; STUB_REX=noblocks run --apply
if [ "$RC" = 1 ] && has "can't verify" && ! installed && [ ! -e "$DST" ]; then
  ok "a Rex server with no pane to probe with: can't verify, so refuse"; else bad "a Rex server with no pane to probe with: can't verify, so refuse"; fi
fresh; STUB_REX=down run --apply
if [ "$RC" = 1 ] && ! installed && [ ! -e "$DST" ]; then
  ok "an unreachable Rex server: refuse"; else bad "an unreachable Rex server: refuse"; fi
NOREX="$TMP/stub-norex"; mkdir -p "$NOREX"; cp -p "$STUB"/* "$NOREX/"; rm -f "$NOREX/rex"
fresh; STUB_PATH="$NOREX" run --apply
if [ "$RC" = 1 ] && has "rex" && ! installed && [ ! -e "$DST" ]; then
  ok "no rex CLI: refuse"; else bad "no rex CLI: refuse"; fi
fresh; NO_XDG=1 run --apply
if [ "$RC" = 1 ] && has "XDG_RUNTIME_DIR" && ! installed && [ ! -e "$DST" ]; then
  ok "Linux without XDG_RUNTIME_DIR (rexume install would fail): refuse"; else bad "Linux without XDG_RUNTIME_DIR (rexume install would fail): refuse"; fi
fresh; STUB_REXUME_INSTALL_FAIL=1 run --apply
if [ "$RC" = 1 ] && has "could not reach the user manager"; then
  ok "a failing rexume install is a failure, with its message"; else bad "a failing rexume install is a failure, with its message"; fi

# --- the work Pi profile never gets the extension ----------------------------------------------
fresh shared; run --apply
if [ "$RC" = 1 ] && has "agent-work" && has "shares" && ! installed && [ ! -e "$DST" ] && [ ! -e "$PERSONAL_EXT" ]; then
  ok "a work profile sharing ~/.pi/agent/extensions makes --apply refuse before installing anything"; else bad "a work profile sharing ~/.pi/agent/extensions makes --apply refuse before installing anything"; fi
fresh shared; run
if [ "$RC" = 0 ] && has "would refuse"; then
  ok "dry-run reports that --apply would refuse a shared extensions directory"; else bad "dry-run reports that --apply would refuse a shared extensions directory"; fi
fresh; mkdir -p "$HOMEDIR/.pi/agent-other/extensions"; : > "$HOMEDIR/.pi/agent-other/extensions/rexume.ts"; run --apply
if [ "$RC" = 1 ] && has "agent-other/extensions/rexume.ts" && ! installed; then
  ok "an existing rexume.ts in any work profile makes --apply refuse"; else bad "an existing rexume.ts in any work profile makes --apply refuse"; fi
fresh; run --apply; : > "$WORK_EXT"; run --check
if [ "$RC" = 1 ] && has "agent-work/extensions/rexume.ts"; then
  ok "--check exits 1 when a work profile has rexume.ts"; else bad "--check exits 1 when a work profile has rexume.ts"; fi
fresh; run --apply; rm -rf "$HOMEDIR/.pi/agent-work/extensions"; ln -s "$HOMEDIR/.pi/agent/extensions" "$HOMEDIR/.pi/agent-work/extensions"
run --check
if [ "$RC" = 1 ] && has "agent-work"; then
  ok "--check exits 1 when a work profile shares the extensions directory that holds rexume.ts"; else bad "--check exits 1 when a work profile shares the extensions directory that holds rexume.ts"; fi

# --- Linux: --check exit codes ----------------------------------------------------------------
fresh; run --apply; rm -f "$TMP/daemon-active"; run --check
if [ "$RC" = 1 ] && has "not active"; then
  ok "--check exits 1 when the daemon is not active"; else bad "--check exits 1 when the daemon is not active"; fi
fresh; run --apply; rm -f "$PERSONAL_EXT"; run --check
if [ "$RC" = 1 ] && has ".pi/agent/extensions/rexume.ts"; then
  ok "--check exits 1 when the personal Pi extension is missing"; else bad "--check exits 1 when the personal Pi extension is missing"; fi
fresh; run --apply; STUB_HOOKS_MISSING='["Stop"]' run --check
if [ "$RC" = 1 ] && has "Stop"; then
  ok "--check exits 1 when rexume status reports missing Claude Code hooks"; else bad "--check exits 1 when rexume status reports missing Claude Code hooks"; fi
fresh; run --apply; printf '#!/bin/sh\ntouch "%s/ran-differing"\n' "$TMP" > "$DST"; chmod 755 "$DST"; : > "$TMP/calls"; run --check
if [ "$RC" = 1 ] && has "differs from the pinned 9.9.9 build" && [ ! -e "$TMP/ran-differing" ] && ! called "rexume "; then
  ok "--check exits 1 for a binary that differs from the pin, and never runs it"; else bad "--check exits 1 for a binary that differs from the pin, and never runs it"; fi
run --apply
if [ "$RC" = 1 ] && has "--force" && [ ! -e "$TMP/ran-differing" ]; then
  ok "--apply leaves a differing binary alone without --force"; else bad "--apply leaves a differing binary alone without --force"; fi
run --apply --force
if [ "$RC" = 0 ] && [ "$(sha "$DST")" = "$BINARY_SHA" ] && [ -n "$(find "$HOMEDIR/.local/state/dotfiles/rexume-backups" -type f -name rexume)" ]; then
  ok "--apply --force backs up the differing binary, then installs the pin"; else bad "--apply --force backs up the differing binary, then installs the pin"; fi
fresh; : > "$PERSONAL_EXT"; run --check
if [ "$RC" = 1 ]; then
  ok "--check exits 1 (not 3) for a partial install"; else bad "--check exits 1 (not 3) for a partial install"; fi
fresh; mkdir -p "$HOMEDIR/.local/bin" "$TMP/elsewhere"; ln -s "$TMP/elsewhere/x" "$DST"; run --apply --force
if [ "$RC" = 1 ] && has symlink && [ -L "$DST" ] && ! installed; then
  ok "a symlink at ~/.local/bin/rexume is refused"; else bad "a symlink at ~/.local/bin/rexume is refused"; fi
fresh; STUB_ARCH=aarch64 run --apply
if [ "$RC" = 1 ] && has "aarch64" && ! installed; then
  ok "Linux on another architecture is refused"; else bad "Linux on another architecture is refused"; fi

# --- macOS: Homebrew ----------------------------------------------------------------------------
fresh; mac --check
if [ "$RC" = 3 ] && has "not installed"; then
  ok "macOS --check exits 3 when not installed"; else bad "macOS --check exits 3 when not installed"; fi
if ! grep "^brew " "$TMP/calls" | grep -vxq "brew --cellar"; then
  ok "macOS checks ask brew only for --cellar"; else bad "macOS checks ask brew only for --cellar"; fi
fresh; before="$(snapshot)"; mac
if [ "$RC" = 0 ] && has "would run: brew install entwining/tap/rexume" && has "rexume install" && ! called "brew install" && ! called "rex " && [ "$(snapshot)" = "$before" ]; then
  ok "macOS dry-run only reports the brew install and the rexume install"; else bad "macOS dry-run only reports the brew install and the rexume install"; fi
fresh; mac --apply
if [ "$RC" = 0 ] && called_x "brew install entwining/tap/rexume" && installed && [ ! -e "$DST" ] && [ -f "$PERSONAL_EXT" ] && [ ! -e "$WORK_EXT" ]; then
  ok "macOS --apply installs with Homebrew, then runs rexume install from Homebrew"; else bad "macOS --apply installs with Homebrew, then runs rexume install from Homebrew"; fi
if ! grep -q "^PI_CODING_AGENT_DIR=" "$TMP/install-env"; then
  ok "macOS rexume install runs without PI_CODING_AGENT_DIR"; else bad "macOS rexume install runs without PI_CODING_AGENT_DIR"; fi
if has "launch_agent=created"; then
  ok "macOS --apply prints the launch agent summary"; else bad "macOS --apply prints the launch agent summary"; fi
: > "$TMP/calls"; mac --check
if [ "$RC" = 0 ] && has "installed with Homebrew" && called "launchctl print gui/" && only_status && ! grep "^brew " "$TMP/calls" | grep -vxq "brew --cellar"; then
  ok "macOS --check passes after install (launchctl print, rexume status only)"; else bad "macOS --check passes after install (launchctl print, rexume status only)"; fi
STUB_LAUNCHD_STATE="not running" mac --check
if [ "$RC" = 1 ] && has "not active"; then
  ok "macOS --check exits 1 when the launch agent is loaded but not running"; else bad "macOS --check exits 1 when the launch agent is loaded but not running"; fi
: > "$TMP/calls"; mac --apply
if [ "$RC" = 0 ] && ! called "brew install" && ! called "brew upgrade" && installed; then
  ok "macOS --apply never reinstalls or upgrades an existing Homebrew install"; else bad "macOS --apply never reinstalls or upgrades an existing Homebrew install"; fi
fresh; brew_has 0.1.30; mac --apply
if [ "$RC" = 0 ] && ! called "brew install" && installed; then
  ok "macOS --apply accepts any Homebrew version"; else bad "macOS --apply accepts any Homebrew version"; fi
fresh; mac --apply --force
if [ "$RC" = 2 ] && ! called "brew install" && ! installed; then
  ok "macOS rejects --apply --force (exit 2)"; else bad "macOS rejects --apply --force (exit 2)"; fi
fresh; mkdir -p "$TMP/otherbin"; cp "$REXUME_SRC" "$TMP/otherbin/rexume"
STUB_PATH="$STUB:$TMP/otherbin" STUB_OS=Darwin STUB_ARCH=arm64 run --apply
if [ "$RC" = 1 ] && has "not from Homebrew" && ! installed && ! called "brew install"; then
  ok "macOS refuses a rexume on PATH that is not from Homebrew"; else bad "macOS refuses a rexume on PATH that is not from Homebrew"; fi
fresh; STUB_OS=Darwin STUB_ARCH=x86_64 run --apply
if [ "$RC" = 1 ] && has "Apple Silicon" && ! called "brew install"; then
  ok "macOS on Intel is refused (upstream ships Apple Silicon only)"; else bad "macOS on Intel is refused (upstream ships Apple Silicon only)"; fi
fresh; STUB_REX=old mac --apply
if [ "$RC" = 1 ] && has "preview.23" && ! called "brew install" && ! installed; then
  ok "macOS: an older Rex server stops before brew install and rexume install"; else bad "macOS: an older Rex server stops before brew install and rexume install"; fi
fresh shared; mac --apply
if [ "$RC" = 1 ] && has "shares" && ! called "brew install" && ! installed; then
  ok "macOS: a shared work-profile extensions directory refuses before brew install"; else bad "macOS: a shared work-profile extensions directory refuses before brew install"; fi
fresh; STUB_BREW_INSTALL_FAIL=1 mac --apply
if [ "$RC" = 1 ] && ! installed; then
  ok "macOS --apply reports a failed brew install as a failure"; else bad "macOS --apply reports a failed brew install as a failure"; fi

# --- never touch the Rex server, systemd, or launchd beyond read-only queries -------------------
if [ ! -s "$UNEXPECTED" ]; then
  ok "no unexpected rex/gh/systemctl/launchctl/brew/rexume call in any test (no server stop/restart, no send)"; else bad "no unexpected rex/gh/systemctl/launchctl/brew/rexume call in any test (no server stop/restart, no send)"; fi
[ -s "$UNEXPECTED" ] && sed 's/^/       /' "$UNEXPECTED"

# --- the committed release.pins -----------------------------------------------------------------
P="$ROOT/config/rexume/release.pins"
if grep -Eq "^REXUME_LINUX_X86_64_ARCHIVE_SHA256=[0-9a-f]{64}$" "$P" && grep -Eq "^REXUME_LINUX_X86_64_BINARY_SHA256=[0-9a-f]{64}$" "$P" \
   && grep -Eq "^REXUME_RELEASE_URL=https://github\.com/Entwining/rexume/releases/download/v[0-9.]+$" "$P" \
   && grep -Fxq "REXUME_ATTESTATION_SIGNER_WORKFLOW=Entwining/rexume/.github/workflows/publish.yml" "$P"; then
  ok "the committed release.pins pins https URLs, full sha256 checksums and the signer workflow"; else bad "the committed release.pins pins https URLs, full sha256 checksums and the signer workflow"; fi
if git -C "$ROOT" ls-files config/rexume | grep -iE '(^|/)\.env|\.env($|\.)|secret|credential|\.pem$|id_rsa' >/dev/null; then
  bad "no tracked rexume file looks secret-sensitive to ./dot doctor"
else ok "no tracked rexume file looks secret-sensitive to ./dot doctor"; fi

echo
echo "rexume tests: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
