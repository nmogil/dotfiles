#!/usr/bin/env bash
# Tests for `./dot update` (scripts/update.sh). Everything runs against
# temporary git repos, a temporary HOME, and a stub `dot` that records which
# subcommands update.sh invokes. No live config, network, Pi, or Rex is used.
# update.sh runs under the same bash as this suite ($BASH), so running the
# suite with /bin/bash on macOS covers bash 3.2.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); [ -f "$OUT" ] && sed 's/^/     | /' "$OUT"; }
die() { printf 'FATAL fixture setup failed: %s\n' "$1" >&2; exit 2; }

# Canonical temp dir: the private repo path must be canonical, and macOS
# mktemp returns /var/... which resolves to /private/var/...
TMP="$(mktemp -d)" || die "mktemp"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)" || die "canonical TMP"
OUT="$TMP/out"

# --- isolated environment -----------------------------------------------------
unset DOTFILES_LOCAL_ENV XDG_CONFIG_HOME NO_COLOR REX_BIN REX_BIN_DIR \
  DOTFILES_PI_CONFIG_DIR DOTFILES_PI_SCAFFOLD_DIR DOTFILES_PRIVATE_REMOTE DOTFILES_REX_OVERLAY_DIR \
  GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE 2>/dev/null || true
export HOME="$TMP/home"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$HOME" "$TMP/bin" "$TMP/gitstub" || die "mkdir"

# --- stubs -------------------------------------------------------------------
# uname: lets a test choose the OS update.sh sees; everything else is real.
REAL_UNAME="$(command -v uname)" || die "uname"
cat > "$TMP/bin/uname" <<EOF || die "uname stub"
#!/bin/sh
if [ "\${1:-}" = -s ] && [ -n "\${STUB_UNAME:-}" ]; then echo "\$STUB_UNAME"; exit 0; fi
exec "$REAL_UNAME" "\$@"
EOF
chmod +x "$TMP/bin/uname" || die "chmod"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/rex" && chmod +x "$TMP/bin/rex" || die "rex stub"
# pi: a global npm install stub: $TMP/pinpm/bin/pi -> ../lib/node_modules/<pkg>/
# dist/cli.js, version in the package's package.json (pi_pkg_version sets it;
# 1.6.0 after fresh). EVERY launch is logged to $PI_LAUNCHES, so a test can
# prove a run never started Pi. `pi update` is also logged to $STUB_LOG (with
# its working directory), moves to $STUB_PI_LATEST when that differs, fails
# with STUB_PI_UPDATE_FAIL, exits 0 without updating or confirming with
# STUB_PI_UNCONFIRMED, and appends to the file $STUB_PI_DIRTY (simulating a
# checkout that changes while it runs). use_pi swaps in a non-npm stub or none.
PI_PREFIX="$TMP/pinpm"
PI_PKG="$PI_PREFIX/lib/node_modules/@earendil-works/pi-coding-agent"
PI_LAUNCHES="$TMP/pi.launches"
mkdir -p "$PI_PKG/dist" "$PI_PREFIX/bin" "$TMP/plainpi" || die "mkdir"
pi_pkg_version() {  # pi_pkg_version [<version>]: set or print the installed version
  if [ "$#" = 1 ]; then
    printf '{\n\t"name": "@earendil-works/pi-coding-agent",\n\t"version": "%s"\n}\n' "$1" > "$PI_PKG/package.json" \
      || die "package.json"
  else
    sed -n 's/^.*"version": "\(.*\)".*$/\1/p' "$PI_PKG/package.json"
  fi
}
cat > "$PI_PKG/dist/cli.js" <<EOF || die "pi stub"
#!/bin/sh
printf '%s @ %s\n' "\$*" "\$PWD" >> "$PI_LAUNCHES"
pkg="$PI_PKG/package.json"
version="\$(sed -n 's/^.*"version": "\(.*\)".*\$/\1/p' "\$pkg")"
case "\${1:-}" in
  --version) echo "\$version" ;;
  update)
    [ -z "\${STUB_LOG:-}" ] || printf 'pi-cli %s @ %s\n' "\$*" "\$PWD" >> "\$STUB_LOG"
    [ -z "\${STUB_PI_DIRTY:-}" ] || echo "changed during pi update" >> "\$STUB_PI_DIRTY"
    if [ -n "\${STUB_PI_UPDATE_FAIL:-}" ]; then
      echo "Error: Could not determine latest pi version: stub network down" >&2; exit 1
    fi
    if [ -n "\${STUB_PI_UNCONFIRMED:-}" ]; then
      echo "Ran npm install -g @earendil-works/pi-coding-agent@9.9.9, but \\\`pi --version\\\` reports \$version, not 9.9.9."
      exit 0
    fi
    if [ -n "\${STUB_PI_LATEST:-}" ] && [ "\$STUB_PI_LATEST" != "\$version" ]; then
      printf '{\n\t"name": "@earendil-works/pi-coding-agent",\n\t"version": "%s"\n}\n' "\$STUB_PI_LATEST" > "\$pkg" || exit 1
      echo "Updated pi from \$version to \$STUB_PI_LATEST"
    else
      echo "pi is already up to date (v\$version)"
    fi ;;
  *) echo "stub pi: unsupported \$*" >&2; exit 2 ;;
esac
EOF
printf '#!/bin/sh\n[ "$1" = --version ] && echo 1.6.0 && exit 0\necho "plain pi $*" >> "$STUB_LOG"; exit 0\n' \
  > "$TMP/plainpi/pi" || die "plain pi stub"
chmod +x "$PI_PKG/dist/cli.js" "$TMP/plainpi/pi" || die "chmod"
use_pi() {  # use_pi npm|plain|none: what update.sh finds as pi on PATH
  rm -f "$PI_PREFIX/bin/pi" || die "rm pi"
  case "$1" in
    npm) ln -s ../lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js "$PI_PREFIX/bin/pi" ;;
    plain) cp "$TMP/plainpi/pi" "$PI_PREFIX/bin/pi" ;;
  esac || die "use_pi $1"
}
pi_pkg_version 1.6.0
use_pi npm
export PATH="$PI_PREFIX/bin:$TMP/bin:$PATH"

# git wrapper (on PATH only while update.sh runs): logs every invocation to
# $STUB_GIT_LOG and fails the subcommand named by $STUB_GIT_FAIL.
REAL_GIT="$(command -v git)" || die "git"
cat > "$TMP/gitstub/git" <<EOF || die "git stub"
#!/bin/sh
sub=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in -C|-c) skip=1 ;; -*) ;; *) sub="\$a"; break ;; esac
done
[ -z "\${STUB_GIT_LOG:-}" ] || printf '%s\n' "\$*" >> "\$STUB_GIT_LOG"
if [ -n "\$sub" ] && [ "\$sub" = "\${STUB_GIT_FAIL:-}" ]; then
  echo "fatal: stub \$sub failure" >&2; exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMP/gitstub/git" || die "chmod"

# Stub `dot`: records argv (and, for Pi commands, the DOTFILES_PI_CONFIG_DIR it
# was given), prints output shaped like the real commands, and fails when its
# argv starts with $STUB_FAIL. For `pi config apply` the --protect-local /
# --previous-bundle guard flags are logged separately to $STUB_LOG.guard
# ("unguarded", "protect none", or "protect <previous manifest.json>") and
# the previous bundle's path to $STUB_LOG.prevpath; with STUB_LOCAL_CHANGE a
# guarded apply reports a local change and exits 3. STUB_REX_REPLACE makes the
# Rex preview report a differing file; STUB_REAL_REX runs the real
# scripts/setup-rex-config.sh instead, and STUB_REAL_PI the real
# scripts/sync-pi-config.sh (with the stub `pi` above). STUB_TMP_WATCH: record what exists in
# that directory at each call.
STUB_DOT="$TMP/stub-dot"
cat > "$STUB_DOT" <<'EOF' || die "dot stub"
#!/usr/bin/env bash
if [ -n "${STUB_REAL_PI:-}" ] && [ "${1:-} ${2:-}" = "pi config" ]; then
  printf '%s\n' "$*" >> "$STUB_LOG"; shift 2
  exec bash "$(dirname "$0")/scripts/sync-pi-config.sh" "$@"
fi
guard=""
if [ "${1:-} ${2:-} ${3:-}" = "pi config apply" ]; then
  guard=unguarded; prev=""; rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --protect-local) guard="protect none" ;;
      --previous-bundle) prev="$2"; shift ;;
      *) rest+=("$1") ;;
    esac
    shift
  done
  set -- "${rest[@]}"
  if [ -n "$prev" ]; then
    guard="protect $(cat "$prev/manifest.json" 2>/dev/null || echo missing)"
    printf '%s\n' "$prev" >> "$STUB_LOG.prevpath"
  fi
  printf '%s\n' "$guard" >> "$STUB_LOG.guard"
fi
printf '%s\n' "$*" >> "$STUB_LOG"
case "$*" in "pi config"*) printf '%s\n' "${DOTFILES_PI_CONFIG_DIR-<unset>}" >> "$STUB_LOG.bundle" ;; esac
[ -z "${STUB_TMP_WATCH:-}" ] || ls -A "$STUB_TMP_WATCH" >> "$STUB_LOG.tmp"
if [ -n "${STUB_REAL_REX:-}" ] && [ "${1:-} ${2:-}" = "rex config" ]; then
  shift 2; exec bash "$(dirname "$0")/scripts/setup-rex-config.sh" "$@"
fi
case "$*" in "${STUB_FAIL:-<none>}"*)
  for i in $(seq 1 30); do echo "noisy line $i"; done
  echo "stub failure for: $*" >&2
  exit 1 ;;
esac
if [ -n "${STUB_LOCAL_CHANGE:-}" ] && [ "$*" = "pi config check" ]; then
  echo "drift  .pi/agent/local-edit.ts"; echo "3 managed files; 1 differ; 0 retired."; exit 1
fi
if [ -n "${STUB_LOCAL_CHANGE:-}" ] && [ "${guard%% *}" = protect ]; then
  echo "local change  .pi/agent/local-edit.ts"
  echo "pi-config: 1 live file(s) differ from the previous baseline" >&2
  exit 3
fi
case "$*" in
  "pi config apply"*|"pi config check")
    echo "Pi CLI: 1.6.0 (minimum 1.6.0)"
    echo "drift  .pi/agent/example.ts"
    echo "3 managed files; 1 differ; 0 retired. Unmanaged files preserved." ;;
  "pi config packages"*) echo "Pi CLI: 1.6.0 (minimum 1.6.0)"; echo "would install npm:example@1.0.0" ;;
  "rex config --apply")
    if [ -n "${STUB_REX_APPLY_DIFFERS:-}" ]; then
      echo "Existing config differs: /x/init.lua. Review first; --force makes backups." >&2; exit 1
    fi
    echo "init.lua: OK"; echo "Rex configuration matches; 0 file(s) installed."
    echo "Run rex config reload to apply the binding without restarting sessions." ;;
  "rex config --check")
    echo "init.lua: OK"; echo "Rex configuration matches; 0 file(s) installed."
    echo "Run rex config reload to apply the binding without restarting sessions." ;;
  "rex config --dry-run")
    echo "Rex config: /x/init.lua"; echo "would install /x/rex-image-paste/init.lua"
    [ -z "${STUB_REX_REPLACE:-}" ] \
      || echo "would replace /x/init.lua (differs; --apply needs --force, which backs it up)"
    echo "No files changed. Use --apply to install; --check to validate the installed copy." ;;
  "rex install --check") echo "rex-safe-upgrade and Pi pane recorder match source." ;;
  "rexboard --check")
    case "${STUB_REXBOARD:-match}" in
      missing) echo "rexboard is not installed at /x/rexboard (./dot rexboard --apply)"; exit 3 ;;
      differs) echo "rexboard at /x/rexboard differs from the pinned 0.36.0 build (rexboard 0.37.0)" >&2; exit 1 ;;
      *) echo "rexboard 0.37.0 installed with Homebrew (vanducng/tap/rexboard); Homebrew manages its version." ;;
    esac ;;
  "rexume --check"|"rexume --check --no-status")
    case "${STUB_REXUME:-installed}" in
      missing) echo "rexume is not installed (./dot rexume --apply)"; exit 3 ;;
      problem)
        echo "rexume 0.1.28 installed with Homebrew (entwining/tap/rexume); Homebrew manages its version."
        printf '%s\n' "rexume is not fully installed:" "  the rexume daemon is not active (systemctl --user status rexume)" >&2
        exit 1 ;;
      *) echo "rexume 0.1.28 installed with Homebrew (entwining/tap/rexume); Homebrew manages its version."
         echo "rexume is installed: binary, daemon active, personal Pi extension; no work Pi profile on this machine." ;;
    esac ;;
esac
EOF
chmod +x "$STUB_DOT" || die "chmod"

# --- fixtures ----------------------------------------------------------------
# Any fixture failure aborts the whole suite: a half-built fixture would make
# later assertions meaningless.
git_q() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1 || die "git $*"; }

# Remotes live under an "owner" directory so the default companion-remote rule
# (same owner as the public origin, repo dotfiles-private) applies to them.
PUB_URL="$TMP/remotes/owner/dotfiles.git"
PRIV_URL="$TMP/remotes/owner/dotfiles-private.git"
PUB_KEY="$TMP/remotes/owner/dotfiles" PRIV_KEY="$TMP/remotes/owner/dotfiles-private"

# new_remote <url> <seed> <populate-fn>: bare origin + seeded content on main.
new_remote() {
  local url="$1" seed="$2" populate="$3"
  git_q init --bare "$url"
  git_q init "$seed"
  (cd "$seed" && "$populate") || die "populate $seed"
  git_q -C "$seed" add -A
  git_q -C "$seed" commit -m init
  git_q -C "$seed" remote add origin "$url"
  git_q -C "$seed" push -u origin main
}
populate_public() {
  mkdir -p scripts/lib \
    && cp "$ROOT/scripts/update.sh" scripts/update.sh \
    && cp "$ROOT/scripts/lib/local-env.sh" "$ROOT/scripts/lib/pi-cli.sh" "$ROOT/scripts/lib/pi_version.py" scripts/lib/ \
    && cp "$ROOT/scripts/setup-rex-config.sh" scripts/setup-rex-config.sh \
    && cp "$ROOT/scripts/sync-pi-config.sh" "$ROOT/scripts/sync-pi-config.py" scripts/ \
    && mkdir -p config && cp -R "$ROOT/config/rex" config/rex \
    && cp "$STUB_DOT" dot \
    && echo '# fake dotfiles' > README.md
}
populate_private() {
  mkdir -p pi-scaffold pi-config \
    && echo '{}' > pi-scaffold/package.json \
    && echo '{"piVersion":"1.6.0"}' > pi-config/manifest.json \
    && printf 'secret.local\n' > .gitignore
}
# commit_upstream <seed-name> <fn>: run fn in the seed clone, commit, push.
commit_upstream() {
  (cd "$TMP/seed-$1" && "$2") || die "upstream change in $1"
  git_q -C "$TMP/seed-$1" add -A
  git_q -C "$TMP/seed-$1" commit -m "upstream change"
  git_q -C "$TMP/seed-$1" push origin main
}
bump() { echo "$RANDOM" >> CHANGES; }
push_upstream() { commit_upstream "$1" bump; }

write_local_env() {  # write_local_env <lines...>
  printf '%s\n' "$@" > "$HOME/.config/dotfiles/local.env" || die "local.env"
}

fresh() {  # rebuild remotes + clones for one scenario
  rm -rf "$TMP/remotes" "$TMP"/seed-* "$TMP/public" "$TMP/private" "$HOME" || die "cleanup"
  mkdir -p "$TMP/remotes/owner" "$HOME/.local/bin" "$HOME/.config/dotfiles" || die "mkdir"
  new_remote "$PUB_URL" "$TMP/seed-public" populate_public
  new_remote "$PRIV_URL" "$TMP/seed-private" populate_private
  git_q clone "$PUB_URL" "$TMP/public"
  git_q clone "$PRIV_URL" "$TMP/private"
  write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/private/pi-scaffold\""
  printf '#!/bin/sh\n' > "$HOME/.local/bin/rex-safe-upgrade" || die "rex-safe-upgrade"
  : > "$TMP/calls" || die "calls"
  rm -f "$TMP"/calls.* || die "cleanup"
  : > "$TMP/gitlog" || die "gitlog"
  rm -f "$PI_LAUNCHES" || die "cleanup"
  pi_pkg_version 1.6.0
  use_pi npm
}

# run_update [args...]: run the copied update.sh from the fake public repo
# under this suite's bash, with the git wrapper on PATH.
run_update() {
  (cd "$TMP/public" && PATH="$TMP/gitstub:$PATH" STUB_LOG="$TMP/calls" STUB_GIT_LOG="$TMP/gitlog" \
    STUB_UNAME="${STUB_UNAME:-Darwin}" REX_BIN="${TEST_REX_BIN-$TMP/bin/rex}" \
    "$BASH" scripts/update.sh "$@") > "$OUT" 2>&1 < /dev/null
  RC=$?
}
has()   { grep -Fq -- "$1" "$OUT"; }
called(){ grep -Fxq -- "$1" "$TMP/calls"; }
count_calls() { grep -Fxc -- "$1" "$TMP/calls"; }
head_of() { git -C "$1" rev-parse HEAD; }
upstream_of() { git -C "$1" rev-parse '@{u}'; }
remote_head() { git --git-dir="$1" rev-parse main; }
show_calls() { printf '     calls:\n'; sed 's/^/       /' "$TMP/calls"; }
TAB="$(printf '\t')"
reset_calls() { : > "$TMP/calls" && : > "$TMP/gitlog" && rm -f "$TMP"/calls.* || die "reset calls"; }
APPLIED_STATE_REL=".local/state/dotfiles/pi-config-applied"
applied_state() { cat "$HOME/$APPLIED_STATE_REL" 2>/dev/null; }
# snapshot <repo>: checksum of every file under .git (objects, refs, index,
# FETCH_HEAD, logs) so a test can prove a run wrote nothing to the repo.
snapshot() { (cd "$1/.git" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done); }

# --- 1: help and argument errors ---------------------------------------------
fresh
run_update --help
[ "$RC" = 0 ] && has "Usage: ./dot update" && has "--dry-run" && has "--fetch" && has "--yes" \
  && [ ! -s "$TMP/calls" ] \
  && ok "--help prints usage and runs nothing" || bad "--help prints usage and runs nothing"
run_update --bogus
[ "$RC" = 2 ] && has "unknown argument" && [ ! -s "$TMP/calls" ] \
  && ok "unknown argument exits 2" || bad "unknown argument exits 2"

run_update --fetch
[ "$RC" = 2 ] && has "--fetch only" && [ ! -s "$TMP/calls" ] \
  && ok "--fetch without --dry-run exits 2" || bad "--fetch without --dry-run exits 2"
run_update --internal-apply-phase --dry-run
[ "$RC" = 2 ] && [ ! -s "$TMP/calls" ] \
  && ok "--internal-apply-phase with --dry-run exits 2" || bad "--internal-apply-phase with --dry-run exits 2"

# --- 2: real run fast-forwards both repos and applies in order -----------------
fresh; push_upstream public; push_upstream private; push_upstream private
run_update
expected_calls="pi-cli update --self --no-approve @ $HOME
pi config apply --apply
pi config packages --apply
pi config check
rex config --dry-run
rex config --apply
rex config --check
rex install --check
rexboard --check
rexume --check"
if [ "$RC" = 0 ] && [ "$(head_of "$TMP/public")" = "$(upstream_of "$TMP/public")" ] \
  && [ "$(head_of "$TMP/private")" = "$(upstream_of "$TMP/private")" ] \
  && has "fast-forwarded 1 commit" && has "fast-forwarded 2 commits" \
  && [ "$(cat "$TMP/calls")" = "$expected_calls" ]; then
  ok "real run: pre-check, fast-forward public+private, Pi CLI update, Pi apply/packages/check, Rex preview/apply/check"
else
  bad "real run: pre-check, fast-forward public+private, Pi CLI update, Pi apply/packages/check, Rex preview/apply/check"
  show_calls
fi
grep -q -- '--force' "$TMP/calls" && bad "never passes --force" || ok "never passes --force"
if grep -q -- 'merge --ff-only --no-overwrite-ignore --no-autostash --quiet [0-9a-f]\{40\}$' "$TMP/gitlog" \
  && grep -q -- 'fetch --quiet --no-tags --no-recurse-submodules --no-prune --no-auto-maintenance --refmap= origin +refs/heads/main:refs/remotes/origin/main$' "$TMP/gitlog" \
  && ! grep -Eq ' fetch( --quiet)?$' "$TMP/gitlog" \
  && ! grep -Eq '(^| )(pull|stash|reset|rebase)( |$)' "$TMP/gitlog" && ! grep -q -- '--force' "$TMP/gitlog"; then
  ok "fast-forwards the exact fetched commit (merge --ff-only --no-overwrite-ignore); never pull/stash/reset/force"
else
  bad "fast-forwards the exact fetched commit (merge --ff-only --no-overwrite-ignore); never pull/stash/reset/force"
  sed 's/^/       git /' "$TMP/gitlog"
fi
[ "$(sort -u "$TMP/calls.bundle")" = "$TMP/private/pi-config" ] \
  && ok "every Pi command gets the one resolved, absolute baseline path" \
  || { bad "every Pi command gets the one resolved, absolute baseline path"; sed 's/^/       /' "$TMP/calls.bundle"; }
has "✓" && has "Repos" && has "Pi config" && has "Rex" \
  && grep -Eq '^Summary: 11 ok, 0 warnings, 0 failed, 0 skipped' "$OUT" \
  && ok "one line per step with section headers and a summary line" \
  || bad "one line per step with section headers and a summary line"
has "3 managed files; 1 differ" && has "    drift  .pi/agent/example.ts" && ! has "Pi CLI: 1.6.0 (minimum" \
  && ok "step output is summarized and indented, not dumped raw" \
  || bad "step output is summarized and indented, not dumped raw"
grep -q $'\033' "$OUT" && bad "no color when stdout is not a TTY" || ok "no color when stdout is not a TTY"

# --- 3: dry-run is read-only; --fetch refreshes remote-tracking refs only -----------
fresh; push_upstream public; push_upstream private
before_pub="$(snapshot "$TMP/public")"; before_priv="$(snapshot "$TMP/private")"
run_update --dry-run
if [ "$RC" = 0 ] && [ "$(snapshot "$TMP/public")" = "$before_pub" ] \
  && [ "$(snapshot "$TMP/private")" = "$before_priv" ] \
  && [ ! -e "$TMP/public/.git/FETCH_HEAD" ] && [ ! -e "$TMP/private/.git/FETCH_HEAD" ] \
  && ! grep -Eq '(^| )fetch( |$)' "$TMP/gitlog" && has "cached" && has "up to date"; then
  ok "dry-run does not fetch: no new objects, refs, index writes, or FETCH_HEAD"
else
  bad "dry-run does not fetch: no new objects, refs, index writes, or FETCH_HEAD"
fi
if ! grep -q -- '--apply' "$TMP/calls" && called "pi config apply" \
  && called "pi config packages" && called "pi config check" && called "rex config --dry-run" \
  && has "    would install npm:example@1.0.0" && has "dry run"; then
  ok "dry-run runs previews and read-only checks only (no --apply), with indented preview lines"
else bad "dry-run runs previews and read-only checks only (no --apply), with indented preview lines"; show_calls; fi

fresh
mkdir -p "$TMP/tmpwatch" || die "mkdir"
STUB_TMP_WATCH="$TMP/tmpwatch" TMPDIR="$TMP/tmpwatch" run_update --dry-run
[ "$RC" = 0 ] && [ -f "$TMP/calls.tmp" ] && [ ! -s "$TMP/calls.tmp" ] && [ -z "$(ls -A "$TMP/tmpwatch")" ] \
  && ok "dry-run keeps step output in memory (no temp files, even transiently)" \
  || { bad "dry-run keeps step output in memory (no temp files, even transiently)"; cat "$TMP/calls.tmp"; }

fresh; push_upstream public; push_upstream private
git_q -C "$TMP/public" fetch
before_refs="$(git -C "$TMP/private" for-each-ref)"
run_update --dry-run
[ "$RC" = 0 ] && has "dotfiles: 1 commit behind" && has "would fast-forward" \
  && [ "$(git -C "$TMP/private" for-each-ref)" = "$before_refs" ] \
  && [ "$(head_of "$TMP/public")" != "$(upstream_of "$TMP/public")" ] \
  && ok "dry-run computes behind counts from cached remote-tracking refs" \
  || bad "dry-run computes behind counts from cached remote-tracking refs"

fresh; push_upstream public; push_upstream private
before_head="$(head_of "$TMP/private")"
run_update --dry-run --fetch
if [ "$RC" = 0 ] && has "dotfiles: 1 commit behind" && has "dotfiles-private: 1 commit behind" \
  && [ "$(head_of "$TMP/private")" = "$before_head" ] \
  && [ "$(upstream_of "$TMP/private")" = "$(remote_head "$PRIV_URL")" ] \
  && [ -z "$(git -C "$TMP/private" status --porcelain)" ] && ! grep -q -- '--apply' "$TMP/calls"; then
  ok "--dry-run --fetch refreshes remote-tracking refs only; HEAD and worktree untouched"
else bad "--dry-run --fetch refreshes remote-tracking refs only; HEAD and worktree untouched"; fi

# --- 4: fast-forward safety ------------------------------------------------------
fresh; push_upstream private
echo local-edit >> "$TMP/private/pi-config/manifest.json"
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 0 ] && has "! dotfiles-private" && has "uncommitted or untracked changes" \
  && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && grep -q local-edit "$TMP/private/pi-config/manifest.json" \
  && [ -z "$(git -C "$TMP/private" stash list)" ]; then
  ok "dirty repo is skipped with a warning; edits kept; nothing stashed"
else bad "dirty repo is skipped with a warning; edits kept; nothing stashed"; fi

fresh; push_upstream private
echo note > "$TMP/private/untracked-note.txt"
before_priv="$(head_of "$TMP/private")"
run_update
if has "! dotfiles-private" && has "uncommitted or untracked changes" \
  && [ "$(head_of "$TMP/private")" = "$before_priv" ] && [ -f "$TMP/private/untracked-note.txt" ]; then
  ok "untracked (non-ignored) files make a repo dirty"
else bad "untracked (non-ignored) files make a repo dirty"; fi

# An ignored local file that an incoming commit would track must survive.
add_secret() { echo upstream-version > secret.local && git add -f secret.local; }
fresh; commit_upstream private add_secret
echo LOCAL-SECRET > "$TMP/private/secret.local"
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 1 ] && has "✗ dotfiles-private: fast-forward refused" \
  && [ "$(cat "$TMP/private/secret.local")" = LOCAL-SECRET ] \
  && [ "$(head_of "$TMP/private")" = "$before_priv" ] && ! called "pi config apply --apply"; then
  ok "ignored local file colliding with an incoming tracked file survives; update refuses"
else bad "ignored local file colliding with an incoming tracked file survives; update refuses"; fi

fresh; push_upstream private
before_priv="$(head_of "$TMP/private")"
STUB_GIT_FAIL=status run_update
if [ "$RC" = 1 ] && has "could not read git status" && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && ! grep -q ' merge ' "$TMP/gitlog"; then
  ok "git status error fails closed (no merge)"
else bad "git status error fails closed (no merge)"; fi

fresh; push_upstream private
before_priv="$(head_of "$TMP/private")"
STUB_GIT_FAIL=rev-list run_update
if [ "$RC" = 1 ] && has "could not count commits" && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && ! grep -q ' merge ' "$TMP/gitlog"; then
  ok "git rev-list error fails closed (no merge)"
else bad "git rev-list error fails closed (no merge)"; fi

fresh; push_upstream public
git -C "$TMP/public" checkout -q --detach || die "detach"
run_update
has "detached HEAD" && [ "$RC" = 0 ] && ok "detached HEAD is skipped with a warning" \
  || bad "detached HEAD is skipped with a warning"

add_mine() { echo mine > mine.txt; }
fresh; push_upstream private
(cd "$TMP/private" && add_mine) || die "mine"
git_q -C "$TMP/private" add mine.txt
git_q -C "$TMP/private" commit -m mine
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 0 ] && has "diverged" && [ "$(head_of "$TMP/private")" = "$before_priv" ]; then
  ok "diverged repo is skipped with a warning and left untouched"
else bad "diverged repo is skipped with a warning and left untouched"; fi

# --- 5: binding the private repo -------------------------------------------------
fresh
write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/missing/pi-scaffold\""
run_update
[ "$RC" = 0 ] && has "! dotfiles-private" && has "not found" \
  && ok "configured-but-absent private repo is a warning" || bad "configured-but-absent private repo is a warning"
grep -q '^pi config' "$TMP/calls" && bad "no Pi steps without a baseline" \
  || { has "no pi-config baseline" && ok "no Pi steps without a baseline" || bad "no Pi steps without a baseline"; }

fresh; push_upstream private
ln -s "$TMP/private" "$TMP/private-link" || die "symlink"
write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/private-link/pi-scaffold\""
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 0 ] && has "not a canonical path" && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && ! called "pi config apply --apply"; then
  ok "non-canonical (symlinked) private repo path is refused"
else bad "non-canonical (symlinked) private repo path is refused"; show_calls; fi
rm -f "$TMP/private-link"

fresh
write_local_env 'DOTFILES_PI_SCAFFOLD_DIR="private/pi-scaffold"'
run_update
[ "$RC" = 0 ] && has "not an absolute path" && ! called "pi config apply --apply" \
  && ok "relative private repo path is refused" || bad "relative private repo path is refused"

fresh; push_upstream private
mkdir -p "$TMP/elsewhere" || die "mkdir"
git_q -C "$TMP/private" config core.worktree "$TMP/elsewhere"
before_priv="$(head_of "$TMP/private")"
run_update
[ "$RC" = 0 ] && has "not the top of its git checkout" && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && ! called "pi config apply --apply" \
  && ok "private path that is not the git toplevel is refused" || bad "private path that is not the git toplevel is refused"

fresh; push_upstream private
mkdir -p "$TMP/remotes/stranger" || die "mkdir"
git_q clone --bare "$PRIV_URL" "$TMP/remotes/stranger/dotfiles-private.git"
git_q -C "$TMP/private" remote set-url origin "$TMP/remotes/stranger/dotfiles-private.git"
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 0 ] && has "not the expected companion remote" && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && ! called "pi config apply --apply" && ! grep -q "private fetch" "$TMP/gitlog"; then
  ok "private repo with an unexpected remote is skipped (not fetched or merged)"
else bad "private repo with an unexpected remote is skipped (not fetched or merged)"; fi

fresh; push_upstream private
mkdir -p "$TMP/remotes/stranger" || die "mkdir"
git_q clone --bare "$PRIV_URL" "$TMP/remotes/stranger/my-private.git"
git_q -C "$TMP/private" remote set-url origin "$TMP/remotes/stranger/my-private.git"
write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/private/pi-scaffold\"" \
  "DOTFILES_PRIVATE_REMOTE=\"$TMP/remotes/stranger/my-private.git\""
run_update
[ "$RC" = 0 ] && [ "$(head_of "$TMP/private")" = "$(upstream_of "$TMP/private")" ] \
  && has "dotfiles-private: fast-forwarded" && called "pi config apply --apply" \
  && ok "DOTFILES_PRIVATE_REMOTE overrides the expected companion remote" \
  || bad "DOTFILES_PRIVATE_REMOTE overrides the expected companion remote"

fresh; push_upstream public; push_upstream private
(cd "$TMP/public" && PATH="$TMP/gitstub:$PATH" STUB_LOG="$TMP/calls" STUB_UNAME=Darwin REX_BIN="$TMP/bin/rex" \
  GIT_DIR="$TMP/private/.git" GIT_WORK_TREE="$TMP/private" GIT_INDEX_FILE="$TMP/private/.git/index" \
  GIT_CONFIG_PARAMETERS="'core.worktree=$TMP/private'" "$BASH" scripts/update.sh) > "$OUT" 2>&1 < /dev/null
RC=$?
if [ "$RC" = 0 ] && [ "$(head_of "$TMP/public")" = "$(remote_head "$PUB_URL")" ] \
  && [ "$(head_of "$TMP/private")" = "$(remote_head "$PRIV_URL")" ] \
  && [ -z "$(git -C "$TMP/private" status --porcelain)" ] && [ -z "$(git -C "$TMP/public" status --porcelain)" ]; then
  ok "inherited GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE/GIT_CONFIG_PARAMETERS are ignored"
else bad "inherited GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE/GIT_CONFIG_PARAMETERS are ignored"; fi

fresh; push_upstream private
write_local_env "DOTFILES_PI_CONFIG_DIR=\"$TMP/private/pi-config\""
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 0 ] && has "dotfiles-private: not configured" && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && ! called "pi config apply --apply" && has "apply + packages skipped"; then
  ok "private repo is not inferred from DOTFILES_PI_CONFIG_DIR alone; Pi apply is skipped"
else bad "private repo is not inferred from DOTFILES_PI_CONFIG_DIR alone; Pi apply is skipped"; show_calls; fi

# --- 6: writes are gated on repo outcomes ------------------------------------------
fresh; push_upstream private
echo local-edit >> "$TMP/private/pi-config/manifest.json"
run_update
if has "! apply + packages skipped — dotfiles-private not updated" \
  && ! called "pi config apply --apply" && ! called "pi config packages --apply" \
  && [ "$(count_calls "pi config check")" = 1 ] && called "rex config --apply"; then
  ok "skipped private repo skips Pi apply/packages (checks still run); Rex apply without overlay still runs"
else bad "skipped private repo skips Pi apply/packages (checks still run); Rex apply without overlay still runs"; show_calls; fi

fresh; push_upstream public
echo local-edit >> "$TMP/public/README.md"
run_update
if has "! dotfiles: skipped" && has "apply + packages skipped — dotfiles not updated" \
  && has "image paste config apply skipped — dotfiles not updated" \
  && ! grep -q -- '--apply' "$TMP/calls" && called "rex config --check" && called "rex install --check"; then
  ok "skipped public repo skips Pi and Rex applies; read-only checks still run"
else bad "skipped public repo skips Pi and Rex applies; read-only checks still run"; show_calls; fi

add_overlay() { mkdir -p rex && echo 'return {}' > rex/private.lua; }
fresh; commit_upstream private add_overlay
git_q -C "$TMP/private" pull --ff-only
push_upstream private
echo local-edit >> "$TMP/private/pi-config/manifest.json"
run_update
if has "image paste config apply skipped — dotfiles-private not updated" \
  && ! called "rex config --apply" && called "rex config --check"; then
  ok "Rex apply needs the private repo when a private overlay exists"
else bad "Rex apply needs the private repo when a private overlay exists"; show_calls; fi

fresh
git -C "$TMP/private" remote set-url origin "$TMP/remotes/owner/missing/dotfiles-private.git" || die "set-url"
write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/private/pi-scaffold\"" \
  "DOTFILES_PRIVATE_REMOTE=\"$TMP/remotes/owner/missing/dotfiles-private.git\""
run_update
[ "$RC" = 1 ] && has "fetch failed" && ! called "pi config apply --apply" \
  && has "apply + packages skipped — dotfiles-private not updated (fetch failed)" \
  && ok "fetch failure is reported, exits 1, and skips dependent applies" \
  || bad "fetch failure is reported, exits 1, and skips dependent applies"

# After fast-forwarding a new updater, the NEW updater runs the apply phase.
new_updater() {
  printf '%s\n' 'echo "NEW-UPDATER-RAN $*"' > "$TMP/marker" \
    && awk -v m="$(cat "$TMP/marker")" '{print} $0 == "section \"Pi config\"" {print m}' \
      scripts/update.sh > scripts/update.sh.new && mv scripts/update.sh.new scripts/update.sh
}
fresh; commit_upstream public new_updater; push_upstream private
run_update
if [ "$RC" = 0 ] && has "NEW-UPDATER-RAN --internal-apply-phase" \
  && [ "$(grep -c 'fast-forwarded' "$OUT")" = 2 ] && [ "$(grep -c ' fetch' "$TMP/gitlog")" = 2 ] \
  && [ "$(count_calls "pi config apply --apply")" = 1 ] && called "rex config --apply" \
  && [ "$(grep -c '^Pi config' "$OUT")" = 1 ] && grep -Eq '^Summary: 11 ok, 0 warnings' "$OUT" \
  && [ "$(grep -c '^pi-cli update' "$TMP/calls")" = 1 ]; then
  ok "an upstream change to the updater re-execs the new updater for the apply phase only"
else bad "an upstream change to the updater re-execs the new updater for the apply phase only"; show_calls; fi

# --- 6b: the Pi CLI is updated first, independently of the repos -----------------
fresh
STUB_PI_LATEST=1.6.1 run_update
if [ "$RC" = 0 ] && has "✓ Pi CLI — 1.6.0 → 1.6.1" && has "running Pi sessions keep 1.6.0 until restarted" \
  && [ "$(head -n 1 "$TMP/calls")" = "pi-cli update --self --no-approve @ $HOME" ] \
  && [ "$(pi_pkg_version)" = 1.6.1 ] && called "pi config apply --apply"; then
  ok "Pi CLI: pi update --self --no-approve runs from \$HOME before the Pi apply and reports old → new"
else bad "Pi CLI: pi update --self --no-approve runs from \$HOME before the Pi apply and reports old → new"; show_calls; fi

fresh
STUB_PI_LATEST=1.6.0 run_update
if [ "$RC" = 0 ] && has "✓ Pi CLI — 1.6.0 (latest)" && ! has "until restarted" \
  && [ "$(count_calls "pi-cli update --self --no-approve @ $HOME")" = 1 ]; then
  ok "Pi CLI: already the latest is reported as (latest), with no restart hint"
else bad "Pi CLI: already the latest is reported as (latest), with no restart hint"; show_calls; fi

fresh
STUB_PI_UPDATE_FAIL=1 run_update
if [ "$RC" = 0 ] && has "! Pi CLI update failed (exit 1)" && has "    Error: Could not determine latest pi version" \
  && called "pi config apply --apply" && called "pi config packages --apply" \
  && grep -Eq '^Summary: 10 ok, 1 warning, 0 failed' "$OUT"; then
  ok "Pi CLI: a failed update is a warning and the run continues (the apply version gate decides)"
else bad "Pi CLI: a failed update is a warning and the run continues (the apply version gate decides)"; show_calls; fi

fresh
STUB_PI_LATEST=1.6.1 run_update --dry-run
if [ "$RC" = 0 ] && has "- Pi CLI: 1.6.0 installed; a real run runs pi update --self" \
  && ! grep -q '^pi-cli' "$TMP/calls" && [ "$(pi_pkg_version)" = 1.6.0 ] && [ ! -e "$PI_LAUNCHES" ]; then
  ok "Pi CLI: --dry-run never runs pi update and writes nothing"
else bad "Pi CLI: --dry-run never runs pi update and writes nothing"; show_calls; fi

fresh
STUB_PI_LATEST=1.6.1 run_update --dry-run --fetch
! grep -q '^pi-cli' "$TMP/calls" && [ "$(pi_pkg_version)" = 1.6.0 ] && [ ! -e "$PI_LAUNCHES" ] \
  && ok "Pi CLI: --dry-run --fetch never runs pi update either" \
  || { bad "Pi CLI: --dry-run --fetch never runs pi update either"; show_calls; }

fresh; use_pi plain
STUB_PI_LATEST=1.6.1 run_update
if [ "$RC" = 0 ] && has "- Pi CLI: not updated — $PI_PREFIX/bin/pi is not a global npm install" \
  && ! grep -q '^plain pi' "$TMP/calls" && ! grep -q '^pi-cli' "$TMP/calls" && called "pi config apply --apply"; then
  ok "Pi CLI: skipped (never run) when pi is not the npm package layout"
else bad "Pi CLI: skipped (never run) when pi is not the npm package layout"; show_calls; fi

# Pi absent: PATH without any pi at all (so a real one can never be reached).
fresh; use_pi none
NO_PI_PATH=""
old_ifs="$IFS"; IFS=:
for dir in $PATH; do [ -x "$dir/pi" ] || NO_PI_PATH="${NO_PI_PATH:+$NO_PI_PATH:}$dir"; done
IFS="$old_ifs"
[ -z "$(PATH="$NO_PI_PATH" command -v pi)" ] || die "PATH without pi"
PATH="$NO_PI_PATH" run_update
if [ "$RC" = 0 ] && has "- Pi CLI: not installed" && ! grep -q '^pi-cli' "$TMP/calls" \
  && called "pi config apply --apply"; then
  ok "Pi CLI: skipped when pi is not installed"
else bad "Pi CLI: skipped when pi is not installed"; show_calls; fi

fresh; push_upstream public
echo local-edit >> "$TMP/public/README.md"
STUB_PI_LATEST=1.6.1 run_update
if has "! dotfiles: skipped" && has "✓ Pi CLI — 1.6.0 → 1.6.1" && ! called "pi config apply --apply"; then
  ok "Pi CLI: updated even when the repos are not verified (it does not come from the repos)"
else bad "Pi CLI: updated even when the repos are not verified (it does not come from the repos)"; show_calls; fi

fresh
STUB_PI_UNCONFIRMED=1 run_update
if [ "$RC" = 0 ] && has "! Pi CLI — 1.6.0 unchanged" && ! has "(latest)" \
  && has "    Ran npm install -g" && called "pi config apply --apply"; then
  ok "Pi CLI: a zero exit that leaves the version unchanged without confirming it is 'unchanged', not 'latest'"
else bad "Pi CLI: a zero exit that leaves the version unchanged without confirming it is 'unchanged', not 'latest'"; show_calls; fi

# A relative PATH entry: the result must not be verified here and run elsewhere.
fresh
PATH="../pinpm/bin:$PATH" run_update
if [ "$RC" = 0 ] && has "- Pi CLI: not updated — ../pinpm/bin/pi" && ! grep -q '^pi-cli' "$TMP/calls" \
  && [ ! -e "$PI_LAUNCHES" ]; then
  ok "Pi CLI: a relative pi path from PATH is never verified or run"
else bad "Pi CLI: a relative pi path from PATH is never verified or run"; show_calls; fi

fresh
pi_pkg_version 1.6
run_update --dry-run
if [ "$RC" = 0 ] && has "- Pi CLI: installed version unavailable" && has "the version gate could not be previewed" \
  && [ ! -e "$PI_LAUNCHES" ]; then
  ok "Pi CLI: --dry-run with an unreadable Pi version says the gate could not be previewed (no Pi launch)"
else bad "Pi CLI: --dry-run with an unreadable Pi version says the gate could not be previewed (no Pi launch)"; fi

# Only a verified @earendil-works/pi-coding-agent manifest counts: a package.json
# naming another package, or a missing/unparsable one, is not the supported
# install, so Pi is never launched (real run or dry run).
not_pi_manifest() {
  case "$1" in
    other-name) printf '{\n\t"name": "evil-package",\n\t"version": "1.6.0"\n}\n' > "$PI_PKG/package.json" ;;
    missing) rm -f "$PI_PKG/package.json" ;;
    unparsable) printf '{"name": "@earendil-works/pi-coding-agent", ' > "$PI_PKG/package.json" ;;
  esac || die "manifest $1"
}
for manifest in other-name missing unparsable; do
  for mode in real dry; do
    fresh; not_pi_manifest "$manifest"
    if [ "$mode" = dry ]; then STUB_PI_LATEST=1.6.1 run_update --dry-run; else STUB_PI_LATEST=1.6.1 run_update; fi
    if [ "$RC" = 0 ] && has "- Pi CLI: not updated — $PI_PREFIX/bin/pi is not a global npm install" \
      && [ ! -e "$PI_LAUNCHES" ] && ! grep -q '^pi-cli' "$TMP/calls"; then
      ok "Pi CLI: package.json $manifest ($mode run) is not the supported install; Pi never launched"
    else bad "Pi CLI: package.json $manifest ($mode run) is not the supported install; Pi never launched"; show_calls; fi
  done
done

# Only a POSITIVELY verified global npm install may run pi update --self: when
# the verifier itself cannot run (python3 missing: 127) or crashes, warn and
# skip — never run whatever pi is on PATH.
mkdir -p "$TMP/py127" "$TMP/pycrash" || die "mkdir"
printf '#!/bin/sh\nexit 127\n' > "$TMP/py127/python3" || die "py127"
printf '#!/bin/sh\necho "Traceback (most recent call last):" >&2\necho "SystemError: stub crash" >&2\nexit 1\n' \
  > "$TMP/pycrash/python3" || die "pycrash"
chmod +x "$TMP/py127/python3" "$TMP/pycrash/python3" || die "chmod"
for broken in py127 pycrash; do
  for kind in plain npm; do
    fresh; use_pi "$kind"
    PATH="$TMP/$broken:$PATH" STUB_PI_LATEST=1.6.1 run_update
    if [ "$RC" = 0 ] && has "! Pi CLI: not updated — could not verify" \
      && ! grep -q '^plain pi' "$TMP/calls" && ! grep -q '^pi-cli' "$TMP/calls" && [ ! -e "$PI_LAUNCHES" ] \
      && [ "$(pi_pkg_version)" = 1.6.0 ] && called "pi config apply --apply"; then
      ok "Pi CLI: verifier $broken + $kind pi: warns, never runs pi, run continues"
    else bad "Pi CLI: verifier $broken + $kind pi: warns, never runs pi, run continues"; show_calls; fi
  done
done
# A verified Pi manifest with an unreadable version (2) is still a verified install.
fresh
pi_pkg_version 1.6
STUB_PI_LATEST=1.6.1 run_update
if [ "$RC" = 0 ] && has "✓ Pi CLI — unknown → 1.6.1" && called "pi-cli update --self --no-approve @ $HOME"; then
  ok "Pi CLI: a verified install with unreadable metadata is still updated"
else bad "Pi CLI: a verified install with unreadable metadata is still updated"; show_calls; fi
fresh
PATH="$TMP/py127:$PATH" run_update --dry-run
[ "$RC" = 0 ] && has "! Pi CLI: not updated — could not verify" && [ ! -e "$PI_LAUNCHES" ] \
  && ok "Pi CLI: --dry-run with a broken verifier warns and launches nothing" \
  || bad "Pi CLI: --dry-run with a broken verifier warns and launches nothing"

# The checkouts are (re-)verified AFTER the long Pi/npm update, so a checkout
# that changes while it runs is not applied from.
fresh; push_upstream public; push_upstream private
STUB_PI_LATEST=1.6.1 STUB_PI_DIRTY="$TMP/public/README.md" run_update
if has "✓ Pi CLI — 1.6.0 → 1.6.1" && has "apply + packages skipped — dotfiles not verified (uncommitted changes)" \
  && has "image paste config apply skipped — dotfiles not verified (uncommitted changes)" \
  && ! grep -q -- '--apply' "$TMP/calls"; then
  ok "Pi CLI: a public checkout that changes during the Pi update is not applied from"
else bad "Pi CLI: a public checkout that changes during the Pi update is not applied from"; show_calls; fi
fresh; push_upstream private
STUB_PI_LATEST=1.6.1 STUB_PI_DIRTY="$TMP/private/pi-config/manifest.json" run_update
if has "apply + packages skipped — dotfiles-private not verified (uncommitted changes)" \
  && ! called "pi config apply --apply" && ! called "pi config packages --apply"; then
  ok "Pi CLI: a private checkout that changes during the Pi update is not applied from"
else bad "Pi CLI: a private checkout that changes during the Pi update is not applied from"; show_calls; fi

# --- 7: uncaptured live Pi changes are protected ----------------------------------
# Apply runs guarded (--protect-local) against the PREVIOUS baseline: the
# private commit this machine last applied successfully (machine-local state
# written only after apply AND packages succeed), copied out of git.
new_manifest() { echo '{"piVersion":"1.6.0","rev":2}' > pi-config/manifest.json; }
fresh
run_update
if [ "$RC" = 0 ] && [ "$(applied_state)" = "$(head_of "$TMP/private")${TAB}pi-config" ] \
  && [ "$(cat "$TMP/calls.guard")" = "protect none" ]; then
  ok "a successful apply + packages records the applied private commit (first run: no previous baseline)"
else bad "a successful apply + packages records the applied private commit (first run: no previous baseline)"; fi

fresh
STUB_FAIL="pi config packages --apply" run_update
[ -z "$(applied_state)" ] && called "pi config apply --apply" \
  && ok "a failed packages step does not record the baseline as applied" \
  || bad "a failed packages step does not record the baseline as applied"
fresh
STUB_LOCAL_CHANGE=1 run_update
[ -z "$(applied_state)" ] && ok "a refused (guarded) apply does not record the baseline as applied" \
  || bad "a refused (guarded) apply does not record the baseline as applied"

fresh; run_update; applied_a="$(head_of "$TMP/private")"
commit_upstream private new_manifest; reset_calls
run_update
prev_path="$(cat "$TMP/calls.prevpath" 2>/dev/null)"
if [ "$(cat "$TMP/calls.guard")" = 'protect {"piVersion":"1.6.0"}' ] && called "pi config apply --apply" \
  && grep -q '"rev":2' "$TMP/private/pi-config/manifest.json" \
  && [ -n "$prev_path" ] && [ "$prev_path" != "$TMP/private/pi-config" ] && [ ! -e "$prev_path" ] \
  && [ "$(applied_state)" = "$(head_of "$TMP/private")${TAB}pi-config" ] && [ "$applied_a" != "$(head_of "$TMP/private")" ]; then
  ok "apply is guarded against the last applied baseline (exported from git, then removed)"
else bad "apply is guarded against the last applied baseline (exported from git, then removed)"; cat "$TMP/calls.guard"; fi

# Regression: the private repo moves A -> B while Pi apply is gated off (the
# public fetch failed). The retry must compare against A (what was applied),
# not B (the private repo's pre-run HEAD).
fresh; run_update
commit_upstream private new_manifest; reset_calls
git -C "$TMP/public" remote set-url origin "$TMP/remotes/owner/missing.git" || die "set-url"
run_update
[ "$RC" = 1 ] && ! called "pi config apply --apply" && grep -q '"rev":2' "$TMP/private/pi-config/manifest.json" \
  || die "gated run did not behave as expected"
git -C "$TMP/public" remote set-url origin "$PUB_URL" || die "set-url"
reset_calls
run_update
[ "$(cat "$TMP/calls.guard")" = 'protect {"piVersion":"1.6.0"}' ] && called "pi config apply --apply" \
  && ok "retry after a gated apply compares against the last applied baseline, not the pre-run HEAD" \
  || { bad "retry after a gated apply compares against the last applied baseline, not the pre-run HEAD"; cat "$TMP/calls.guard"; }

fresh; run_update; push_upstream public; reset_calls
run_update
[ "$(cat "$TMP/calls.guard")" = 'protect {"piVersion":"1.6.0"}' ] \
  && [ "$(cat "$TMP/calls.prevpath")" = "$TMP/private/pi-config" ] \
  && ok "last applied baseline is the current commit: the verified live bundle is the previous baseline" \
  || bad "last applied baseline is the current commit: the verified live bundle is the previous baseline"

fresh; push_upstream private
STUB_LOCAL_CHANGE=1 run_update
if [ "$RC" = 0 ] && has "may hold uncaptured local changes" && has "./dot pi config capture" && has "--yes" \
  && has "    local change  .pi/agent/local-edit.ts" && ! called "pi config packages --apply" \
  && called "pi config check"; then
  ok "a guarded apply that finds local changes skips apply + packages with a review hint"
else bad "a guarded apply that finds local changes skips apply + packages with a review hint"; show_calls; fi

fresh; push_upstream private
STUB_LOCAL_CHANGE=1 run_update --yes
[ "$(cat "$TMP/calls.guard")" = unguarded ] && called "pi config packages --apply" \
  && ok "--yes applies unguarded" || bad "--yes applies unguarded"

rm_config() { git rm -q -r pi-config; }
add_config() { mkdir -p pi-config && echo '{"piVersion":"1.6.0"}' > pi-config/manifest.json; }
fresh; commit_upstream private rm_config
git_q -C "$TMP/private" pull --ff-only
commit_upstream private add_config
run_update
[ "$(cat "$TMP/calls.guard")" = "protect none" ] && called "pi config apply --apply" \
  && ok "no previous baseline: guarded with no previous bundle (every differing live file is protected)" \
  || bad "no previous baseline: guarded with no previous bundle (every differing live file is protected)"

fresh; run_update; reset_calls
STUB_LOCAL_CHANGE=1 run_update --dry-run
[ "$RC" = 0 ] && has "a real update would skip apply" && has "    local change  .pi/agent/local-edit.ts" \
  && ! grep -q -- '--apply' "$TMP/calls" && ! has "would apply it" \
  && [ "$(cat "$TMP/calls.guard")" = 'protect {"piVersion":"1.6.0"}' ] \
  && ok "dry-run previews the guard against the last applied baseline (and does not also say it would apply)" \
  || bad "dry-run previews the guard against the last applied baseline (and does not also say it would apply)"

# End to end with the real Pi tool: a file the incoming baseline starts
# managing, already present on this machine with different content, is a
# local change; the same update without it installs the new file.
SOURCE_HOME="$TMP/source-home"
capture_source() {  # snapshot $SOURCE_HOME into the private seed's pi-config
  rm -rf pi-config && HOME="$SOURCE_HOME" python3 "$TMP/public/scripts/sync-pi-config.py" capture --apply \
    --home "$SOURCE_HOME" --bundle "$PWD/pi-config" >/dev/null
}
real_pi_fixture() {
  rm -rf "$SOURCE_HOME" && mkdir -p "$SOURCE_HOME/.pi/agent/extensions" || die "source home"
  echo '{"theme":"dark","packages":[]}' > "$SOURCE_HOME/.pi/agent/settings.json" || die "settings"
  echo 'export default () => 1;' > "$SOURCE_HOME/.pi/agent/extensions/a.ts" || die "a.ts"
  commit_upstream private capture_source
  git_q -C "$TMP/private" pull --ff-only
  # This machine applied that commit (as a successful ./dot update records it).
  python3 "$TMP/public/scripts/sync-pi-config.py" apply --apply --home "$HOME" \
    --bundle "$TMP/private/pi-config" >/dev/null 2>&1 || die "initial apply"
  mkdir -p "$(dirname "$HOME/$APPLIED_STATE_REL")" \
    && printf '%s\t%s\n' "$(head_of "$TMP/private")" pi-config > "$HOME/$APPLIED_STATE_REL" || die "state"
  echo 'export const fromSource = 1;' > "$SOURCE_HOME/.pi/agent/extensions/new.ts" || die "new.ts"
  commit_upstream private capture_source
}
fresh; real_pi_fixture
echo 'export const mine = 2;' > "$HOME/.pi/agent/extensions/new.ts" || die "local new.ts"
STUB_REAL_PI=1 run_update
if [ "$RC" = 0 ] && has "    local change  .pi/agent/extensions/new.ts" && has "may hold uncaptured local changes" \
  && [ "$(cat "$HOME/.pi/agent/extensions/new.ts")" = 'export const mine = 2;' ] \
  && [ "$(head_of "$TMP/private")" = "$(remote_head "$PRIV_URL")" ] && ! called "pi config packages --apply"; then
  ok "real Pi tool: a pre-existing live file the new baseline starts managing is not overwritten"
else bad "real Pi tool: a pre-existing live file the new baseline starts managing is not overwritten"; show_calls; fi

fresh; real_pi_fixture
STUB_REAL_PI=1 run_update
if [ "$RC" = 0 ] && [ "$(cat "$HOME/.pi/agent/extensions/new.ts")" = 'export const fromSource = 1;' ] \
  && has "✓ apply" && has "✓ check"; then
  ok "real Pi tool: the same update without a local copy installs the new file"
else bad "real Pi tool: the same update without a local copy installs the new file"; fi

# No dry-run path launches Pi (its entry point can write a compile cache or a
# settings lock even for --version): the real sync tool reads package.json.
fresh; real_pi_fixture
rm -f "$PI_LAUNCHES"
STUB_REAL_PI=1 run_update --dry-run
if [ "$RC" = 0 ] && [ ! -e "$PI_LAUNCHES" ] && has "- Pi CLI: 1.6.0 installed" && has "✓ apply (preview)" \
  && called "pi config check"; then
  ok "real Pi tool: --dry-run (Pi CLI, apply/packages previews, check) never launches Pi"
else bad "real Pi tool: --dry-run (Pi CLI, apply/packages previews, check) never launches Pi"; cat "$PI_LAUNCHES" 2>/dev/null; fi
rm -f "$PI_LAUNCHES"
STUB_REAL_PI=1 run_update
if [ "$RC" = 0 ] && [ "$(cat "$PI_LAUNCHES")" = "update --self --no-approve @ $HOME" ]; then
  ok "real Pi tool: a real run launches Pi only for pi update --self"
else bad "real Pi tool: a real run launches Pi only for pi update --self"; cat "$PI_LAUNCHES" 2>/dev/null; fi

# Real Pi tool: a clean update whose apply was gated off once still applies on
# the retry (live = A, incoming = B, last applied = A).
fresh; real_pi_fixture
git -C "$TMP/public" remote set-url origin "$TMP/remotes/owner/missing.git" || die "set-url"
STUB_REAL_PI=1 run_update
[ "$RC" = 1 ] && [ ! -e "$HOME/.pi/agent/extensions/new.ts" ] || die "gated real run"
git -C "$TMP/public" remote set-url origin "$PUB_URL" || die "set-url"
reset_calls
STUB_REAL_PI=1 run_update
if [ "$RC" = 0 ] && [ "$(cat "$HOME/.pi/agent/extensions/new.ts")" = 'export const fromSource = 1;' ] \
  && ! has "local change"; then
  ok "real Pi tool: retry after a gated apply installs the clean update"
else bad "real Pi tool: retry after a gated apply installs the clean update"; fi

# --- 8: Rex replacements need manual review ----------------------------------------
fresh
STUB_REX_REPLACE=1 run_update --dry-run
if [ "$RC" = 0 ] && has "! image paste config: needs manual review (./dot rex config, then --force)" \
  && has "    would replace /x/init.lua" && ! has "would apply"; then
  ok "dry-run reports a differing Rex file as needing manual review"
else bad "dry-run reports a differing Rex file as needing manual review"; fi

fresh
STUB_REX_REPLACE=1 run_update
if [ "$RC" = 0 ] && has "needs manual review (./dot rex config, then --force)" \
  && called "rex config --dry-run" && ! called "rex config --apply"; then
  ok "real run does not apply Rex config when a file needs --force"
else bad "real run does not apply Rex config when a file needs --force"; show_calls; fi

fresh
STUB_REX_APPLY_DIFFERS=1 run_update
if [ "$RC" = 0 ] && has "! image paste config: needs manual review (./dot rex config, then --force) — not applied" \
  && has "    Existing config differs: /x/init.lua" && ! called "rex config --check"; then
  ok "apply refusing a differing Rex file (older preview format) is a review warning, not a failure"
else bad "apply refusing a differing Rex file (older preview format) is a review warning, not a failure"; show_calls; fi

# --- 8b: the fetch is pinned to the verified remote and upstream branch -----------
# A hostile configured refspec would force-update local branches, and fetch.all
# would contact every remote; neither may take effect.
hostile_private() {
  git_q -C "$TMP/seed-private" checkout -b keep
  (cd "$TMP/seed-private" && bump) || die "bump"
  git_q -C "$TMP/seed-private" add -A
  git_q -C "$TMP/seed-private" commit -m "upstream keep"
  git_q -C "$TMP/seed-private" push origin keep
  git_q -C "$TMP/seed-private" checkout main
  push_upstream private
  git_q -C "$TMP/private" branch keep HEAD
  git_q -C "$TMP/private" config --replace-all remote.origin.fetch '+refs/heads/*:refs/heads/*'
  git_q clone --bare "$PRIV_URL" "$TMP/remotes/other.git"
  git_q -C "$TMP/private" remote add other "$TMP/remotes/other.git"
  git_q -C "$TMP/private" config fetch.all true
  KEEP_BEFORE="$(git -C "$TMP/private" rev-parse refs/heads/keep)"
}
fresh; hostile_private
run_update
if [ "$RC" = 0 ] && [ "$(git -C "$TMP/private" rev-parse refs/heads/keep)" = "$KEEP_BEFORE" ] \
  && [ -z "$(git -C "$TMP/private" for-each-ref refs/remotes/other)" ] \
  && [ "$(head_of "$TMP/private")" = "$(remote_head "$PRIV_URL")" ] && called "pi config apply --apply"; then
  ok "hostile refspec and fetch.all: only origin's upstream branch is fetched; local branches untouched"
else bad "hostile refspec and fetch.all: only origin's upstream branch is fetched; local branches untouched"; fi

fresh; hostile_private
run_update --dry-run --fetch
if [ "$RC" = 0 ] && [ "$(git -C "$TMP/private" rev-parse refs/heads/keep)" = "$KEEP_BEFORE" ] \
  && [ -z "$(git -C "$TMP/private" for-each-ref refs/remotes/other)" ] \
  && [ "$(git -C "$TMP/private" rev-parse refs/remotes/origin/main)" = "$(remote_head "$PRIV_URL")" ] \
  && has "dotfiles-private: 1 commit behind origin/main"; then
  ok "--dry-run --fetch with a hostile refspec updates only refs/remotes/origin/main"
else bad "--dry-run --fetch with a hostile refspec updates only refs/remotes/origin/main"; fi

fresh; push_upstream private
git_q -C "$TMP/private" config branch.main.merge refs/heads/gone
before_priv="$(head_of "$TMP/private")"
run_update
[ "$RC" = 1 ] && has "✗ dotfiles-private: fetch failed" && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && ! called "pi config apply --apply" \
  && ok "a missing upstream source branch fails the fetch and skips Pi apply" \
  || bad "a missing upstream source branch fails the fetch and skips Pi apply"

# --- 8c: the apply-phase hand-off is re-verified, not trusted --------------------------
forge_state() {  # a complete, correct hand-off for the current checkouts
  local pub_commit priv_commit
  pub_commit="$(head_of "$TMP/public")" || die "head"
  priv_commit="$(head_of "$TMP/private")" || die "head"
  export DOT_UPDATE_PUBLIC=ok DOT_UPDATE_PUBLIC_DIR="$TMP/public" \
    DOT_UPDATE_PUBLIC_COMMIT="$pub_commit" DOT_UPDATE_PUBLIC_REMOTE="$PUB_KEY" \
    DOT_UPDATE_PRIVATE=ok DOT_UPDATE_PRIVATE_DIR="$TMP/private" \
    DOT_UPDATE_PRIVATE_COMMIT="$priv_commit" DOT_UPDATE_PRIVATE_REMOTE="$PRIV_KEY" \
    DOT_UPDATE_PUBLIC_BEFORE="$pub_commit" DOT_UPDATE_PRIVATE_BEFORE="$priv_commit" \
    DOT_UPDATE_BUNDLE="$TMP/private/pi-config" DOT_UPDATE_COUNTS="2 0 0 0"
}
# fetch_like_update: what the parent updater's fetch leaves behind.
fetch_like_update() {
  git_q -C "$1" fetch --quiet --no-tags --refmap= origin +refs/heads/main:refs/remotes/origin/main
}
unforge() {
  unset DOT_UPDATE_PUBLIC DOT_UPDATE_PUBLIC_DIR DOT_UPDATE_PUBLIC_COMMIT DOT_UPDATE_PUBLIC_REMOTE \
    DOT_UPDATE_PRIVATE DOT_UPDATE_PRIVATE_DIR DOT_UPDATE_PRIVATE_COMMIT DOT_UPDATE_PRIVATE_REMOTE \
    DOT_UPDATE_PUBLIC_BEFORE DOT_UPDATE_PRIVATE_BEFORE DOT_UPDATE_BUNDLE DOT_UPDATE_COUNTS
}
fresh; forge_state
run_update --internal-apply-phase; unforge
[ "$RC" = 0 ] && ! grep -q -- '--apply' "$TMP/calls" && has "freshness not established" && has "--yes" \
  && ! grep -q ' fetch' "$TMP/gitlog" \
  && ok "a matching hand-off without a matching fetch is refused without --yes" \
  || bad "a matching hand-off without a matching fetch is refused without --yes"

fresh; forge_state
run_update --internal-apply-phase --yes; unforge
[ "$RC" = 0 ] && called "pi config apply --apply" && called "rex config --apply" \
  && has "freshness not established" && has "applying because of --yes" \
  && ok "--yes applies a hand-off whose freshness cannot be established" \
  || bad "--yes applies a hand-off whose freshness cannot be established"

fresh; fetch_like_update "$TMP/public"; fetch_like_update "$TMP/private"; forge_state
run_update --internal-apply-phase; unforge
[ "$RC" = 0 ] && called "pi config apply --apply" && called "rex config --apply" && ! grep -q ' fetch' "$TMP/gitlog" \
  && ok "a hand-off matching the fetched refs and FETCH_HEAD runs the apply phase without fetching" \
  || bad "a hand-off matching the fetched refs and FETCH_HEAD runs the apply phase without fetching"

fresh; push_upstream private; fetch_like_update "$TMP/public"; fetch_like_update "$TMP/private"; forge_state
run_update --internal-apply-phase; unforge
! called "pi config apply --apply" && has "dotfiles-private not verified (freshness not established: HEAD does not contain origin/main" \
  && ok "a hand-off for a checkout behind its fetched upstream blocks Pi apply" \
  || bad "a hand-off for a checkout behind its fetched upstream blocks Pi apply"

fresh; fetch_like_update "$TMP/public"; fetch_like_update "$TMP/private"; forge_state
DOT_UPDATE_PRIVATE_BEFORE="$(remote_head "$PUB_URL")"
run_update --internal-apply-phase; unforge
! called "pi config apply --apply" && has "the pre-update commit is not an ancestor of HEAD" \
  && ok "a hand-off whose pre-update commit is not an ancestor of HEAD blocks Pi apply" \
  || bad "a hand-off whose pre-update commit is not an ancestor of HEAD blocks Pi apply"

fresh
export DOT_UPDATE_PUBLIC=ok DOT_UPDATE_PRIVATE=ok
run_update --internal-apply-phase; unforge
[ "$RC" = 1 ] && ! grep -q -- '--apply' "$TMP/calls" && has "hand-off" \
  && ok "status strings alone (no paths/commits) are not proof: nothing applied" \
  || bad "status strings alone (no paths/commits) are not proof: nothing applied"

fresh; fetch_like_update "$TMP/public"; fetch_like_update "$TMP/private"; forge_state; DOT_UPDATE_PRIVATE_COMMIT="$(remote_head "$PUB_URL")"
run_update --internal-apply-phase; unforge
! called "pi config apply --apply" && has "apply + packages skipped — dotfiles-private not verified" \
  && called "rex config --apply" \
  && ok "hand-off commit that is not HEAD blocks Pi apply" || bad "hand-off commit that is not HEAD blocks Pi apply"

fresh; fetch_like_update "$TMP/public"; fetch_like_update "$TMP/private"; forge_state; echo local-edit >> "$TMP/private/pi-config/manifest.json"
run_update --internal-apply-phase; unforge
! called "pi config apply --apply" && has "dotfiles-private not verified" \
  && ok "dirty tree at apply time blocks Pi apply" || bad "dirty tree at apply time blocks Pi apply"

fresh; fetch_like_update "$TMP/public"; fetch_like_update "$TMP/private"; forge_state; DOT_UPDATE_PUBLIC_DIR="$TMP/private"
run_update --internal-apply-phase; unforge
! grep -q -- '--apply' "$TMP/calls" && has "dotfiles not verified" \
  && ok "hand-off for a different public checkout blocks all applies" \
  || bad "hand-off for a different public checkout blocks all applies"

fresh; fetch_like_update "$TMP/public"; fetch_like_update "$TMP/private"; forge_state; DOT_UPDATE_PRIVATE_REMOTE="$TMP/remotes/stranger/dotfiles-private"
run_update --internal-apply-phase; unforge
! called "pi config apply --apply" && has "dotfiles-private not verified" \
  && ok "hand-off remote that does not match blocks Pi apply" || bad "hand-off remote that does not match blocks Pi apply"

# --- 8d: the Pi baseline must come from the verified private commit ----------------
fresh; push_upstream private
write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/private/pi-scaffold\"" 'DOTFILES_PI_CONFIG_DIR="../private/pi-config"'
run_update
[ "$(sort -u "$TMP/calls.bundle")" = "$TMP/private/pi-config" ] && called "pi config apply --apply" \
  && ok "relative DOTFILES_PI_CONFIG_DIR resolves once against \$HOME, like the Pi tool" \
  || { bad "relative DOTFILES_PI_CONFIG_DIR resolves once against \$HOME, like the Pi tool"; cat "$TMP/calls.bundle"; }

fresh; push_upstream private
echo leftover > "$TMP/private/pi-config/secret.local"
run_update
! called "pi config apply --apply" && has "apply + packages skipped — baseline" && has "differs from the verified commit (pi-config/secret.local" \
  && called "rex config --apply" \
  && ok "an ignored file inside the baseline blocks Pi apply" || bad "an ignored file inside the baseline blocks Pi apply"

fresh
mkdir -p "$TMP/private/pi-local" || die "mkdir"
echo '{"piVersion":"1.6.0"}' > "$TMP/private/pi-local/manifest.json" || die "manifest"
echo 'pi-local/' >> "$TMP/private/.git/info/exclude" || die "exclude"
write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/private/pi-scaffold\"" "DOTFILES_PI_CONFIG_DIR=\"$TMP/private/pi-local\""
run_update
! called "pi config apply --apply" && has "is not tracked at the verified commit" \
  && ok "an untracked baseline blocks Pi apply" || bad "an untracked baseline blocks Pi apply"

fresh
mkdir -p "$TMP/outside" || die "mkdir"
echo '{"piVersion":"1.6.0"}' > "$TMP/outside/manifest.json" || die "manifest"
write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/private/pi-scaffold\"" "DOTFILES_PI_CONFIG_DIR=\"$TMP/outside\""
run_update
! called "pi config apply --apply" && has "outside the private repo" \
  && ok "a baseline outside the private repo blocks Pi apply" || bad "a baseline outside the private repo blocks Pi apply"

for flag in assume-unchanged skip-worktree; do
  fresh; push_upstream private
  echo '{"piVersion":"9.9.9"}' > "$TMP/private/pi-config/manifest.json" || die "edit"
  git_q -C "$TMP/private" update-index "--$flag" pi-config/manifest.json
  [ -z "$(git -C "$TMP/private" status --porcelain --ignored)" ] || die "$flag did not hide the edit"
  run_update
  if ! called "pi config apply --apply" \
    && has "differs from the verified commit (pi-config/manifest.json"; then
    ok "a tracked baseline edit hidden by $flag blocks Pi apply"
  else bad "a tracked baseline edit hidden by $flag blocks Pi apply"; fi
done

# A FIFO (git status ignores it) inside the baseline must be rejected without
# being opened; the watchdog unblocks a reader so a regression fails, not hangs.
fresh; push_upstream private
mkfifo "$TMP/private/pi-config/pipe" || die "mkfifo"
( sleep 15; exec 3<>"$TMP/private/pi-config/pipe" ) & watchdog=$!
started="$(date +%s)"
run_update
elapsed=$(( $(date +%s) - started ))
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
if [ "$elapsed" -lt 15 ] && ! called "pi config apply --apply" \
  && has "contains a non-regular file (pi-config/pipe)"; then
  ok "a FIFO inside the baseline is rejected as non-regular without hashing it"
else bad "a FIFO inside the baseline is rejected as non-regular without hashing it"; fi

# --- 8f: Rex overlay provenance ---------------------------------------------------------
fresh; commit_upstream private add_overlay
git_q -C "$TMP/private" pull --ff-only
echo leftover > "$TMP/private/rex/secret.local"
run_update
! called "rex config --apply" && has "image paste config apply skipped — overlay" && has "rex/secret.local" \
  && ok "an ignored file inside the private overlay blocks Rex apply" \
  || bad "an ignored file inside the private overlay blocks Rex apply"

fresh
mkdir -p "$TMP/outside-overlay" && echo 'return {}' > "$TMP/outside-overlay/x.lua" || die "overlay"
write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/private/pi-scaffold\"" "DOTFILES_REX_OVERLAY_DIR=\"$TMP/outside-overlay\""
run_update
! called "rex config --apply" && has "outside the private repo" \
  && ok "DOTFILES_REX_OVERLAY_DIR outside the private repo blocks Rex apply" \
  || bad "DOTFILES_REX_OVERLAY_DIR outside the private repo blocks Rex apply"

fresh
# A gitlink (mode 160000) under the overlay; committed without `add -A`, which
# would drop it because no submodule is checked out.
mkdir -p "$TMP/seed-private/rex" && echo 'return {}' > "$TMP/seed-private/rex/private.lua" || die "overlay"
git_q -C "$TMP/seed-private" add rex/private.lua
git_q -C "$TMP/seed-private" update-index --add --cacheinfo \
  "160000,$(git -C "$TMP/seed-private" rev-parse HEAD),rex/vendored"
git_q -C "$TMP/seed-private" commit -m "overlay with a submodule"
git_q -C "$TMP/seed-private" push origin main
git_q -C "$TMP/private" pull --ff-only
[ "$(git -C "$TMP/private" ls-tree HEAD rex/vendored | cut -c1-6)" = 160000 ] || die "no gitlink"
run_update
! called "rex config --apply" && has "image paste config apply skipped — overlay" && has "contains a submodule (rex/vendored)" \
  && ok "a private overlay containing a submodule blocks Rex apply" \
  || bad "a private overlay containing a submodule blocks Rex apply"

# --- 8g: the real Rex installer (stub rex binary) -----------------------------------------
fresh
STUB_REAL_REX=1 run_update
if [ "$RC" = 0 ] && has "✓ image paste config apply" && [ -f "$HOME/.config/rex/rex-image-paste/init.lua" ] \
  && cmp -s "$TMP/public/config/rex/init.lua" "$HOME/.config/rex/init.lua"; then
  ok "real installer: fresh machine installs the Rex config"
else bad "real installer: fresh machine installs the Rex config"; fi

fresh
mkdir -p "$HOME/.config/rex" && echo '-- my local Rex config' > "$HOME/.config/rex/init.lua" || die "init.lua"
STUB_REAL_REX=1 run_update --dry-run
if [ "$RC" = 0 ] && has "! image paste config: needs manual review (./dot rex config, then --force)" \
  && has "would replace $HOME/.config/rex/init.lua" && ! has "pending install"; then
  ok "real installer: dry-run reports a differing init.lua as needing manual review"
else bad "real installer: dry-run reports a differing init.lua as needing manual review"; fi
STUB_REAL_REX=1 run_update
if [ "$RC" = 0 ] && has "needs manual review (./dot rex config, then --force)" && ! called "rex config --apply" \
  && [ "$(cat "$HOME/.config/rex/init.lua")" = '-- my local Rex config' ] \
  && [ ! -e "$HOME/.local/state/dotfiles/rex-backups" ] && [ ! -e "$HOME/.config/rex/rex-image-paste" ]; then
  ok "real installer: a real run leaves a differing init.lua alone and installs nothing"
else bad "real installer: a real run leaves a differing init.lua alone and installs nothing"; show_calls; fi

# --- 9: platform handling --------------------------------------------------------
fresh
STUB_UNAME=Linux run_update
if [ "$RC" = 0 ] && has "skipped (Mac only)" && ! grep -q '^rex config' "$TMP/calls" \
  && called "rex install --check"; then
  ok "Linux skips Rex config (Mac only) but still runs rex install --check"
else bad "Linux skips Rex config (Mac only) but still runs rex install --check"; fi

fresh
rm "$HOME/.local/bin/rex-safe-upgrade" || die "rm"
TEST_REX_BIN="" STUB_UNAME=Linux run_update
! grep -q '^rex ' "$TMP/calls" && has "not installed" \
  && ok "rex install check is skipped when rex-safe-upgrade is not installed" \
  || bad "rex install check is skipped when rex-safe-upgrade is not installed"

# --- 9b: rexboard is checked read-only, never installed or replaced ---------------
fresh
run_update
if [ "$RC" = 0 ] && has "✓ rexboard check — rexboard 0.37.0 installed with Homebrew" \
  && [ "$(count_calls "rexboard --check")" = 1 ] && ! grep -q '^rexboard --apply' "$TMP/calls"; then
  ok "rexboard: an installed board passes a read-only check (never --apply)"
else bad "rexboard: an installed board passes a read-only check (never --apply)"; show_calls; fi
fresh
STUB_REXBOARD=missing run_update
if [ "$RC" = 0 ] && has "- rexboard: not installed (./dot rexboard --apply to opt in)" \
  && ! grep -q '^rexboard --apply' "$TMP/calls" && ! has "! rexboard"; then
  ok "rexboard: not installed is a skip, not a warning, and installs nothing"
else bad "rexboard: not installed is a skip, not a warning, and installs nothing"; fi
fresh
STUB_REXBOARD=differs run_update
if [ "$RC" = 0 ] && has "! rexboard check failed (exit 1)" && has "differs from the pinned 0.36.0 build" \
  && ! grep -q '^rexboard --apply' "$TMP/calls" && grep -Eq '^Summary: .*1 warning, 0 failed' "$OUT"; then
  ok "rexboard: a differing binary is a warning and is left alone"
else bad "rexboard: a differing binary is a warning and is left alone"; fi
fresh
STUB_REXBOARD=differs run_update --dry-run
if [ "$RC" = 0 ] && has "! rexboard check failed (exit 1)" && [ "$(count_calls "rexboard --check")" = 1 ]; then
  ok "rexboard: --dry-run runs the same read-only check"
else bad "rexboard: --dry-run runs the same read-only check"; fi

# --- 9c: rexume is checked read-only, never installed, applied or started ----------------
no_rexume_writes() { ! grep '^rexume ' "$TMP/calls" | grep -vxq -e 'rexume --check' -e 'rexume --check --no-status'; }
fresh
run_update
if [ "$RC" = 0 ] && has "✓ rexume check — rexume is installed: binary, daemon active" \
  && [ "$(count_calls "rexume --check")" = 1 ] && no_rexume_writes; then
  ok "rexume: an installed rexume passes the read-only check (never --apply)"
else bad "rexume: an installed rexume passes the read-only check (never --apply)"; show_calls; fi
fresh
STUB_REXUME=missing run_update
if [ "$RC" = 0 ] && has "- rexume: not installed (opt-in: ./dot rexume --apply)" && ! has "! rexume" \
  && no_rexume_writes && grep -Eq '^Summary: 10 ok, 0 warnings, 0 failed, 1 skipped' "$OUT"; then
  ok "rexume: not installed is a skip, not a warning, and installs nothing"
else bad "rexume: not installed is a skip, not a warning, and installs nothing"; show_calls; fi
fresh
STUB_REXUME=problem run_update
if [ "$RC" = 0 ] && has "! rexume check failed (exit 1)" && has "    rexume is not fully installed:" \
  && has "      the rexume daemon is not active" && no_rexume_writes \
  && grep -Eq '^Summary: 10 ok, 1 warning, 0 failed, 0 skipped' "$OUT"; then
  ok "rexume: a problem is a warning with the check's output indented"
else bad "rexume: a problem is a warning with the check's output indented"; show_calls; fi
fresh
STUB_REXUME=problem run_update --dry-run
if [ "$RC" = 0 ] && has "! rexume check failed (exit 1)" && [ "$(count_calls "rexume --check --no-status")" = 1 ] \
  && [ "$(count_calls "rexume --check")" = 0 ] && no_rexume_writes; then
  ok "rexume: --dry-run checks with --no-status (rexume itself never runs; nothing is written)"
else bad "rexume: --dry-run checks with --no-status (rexume itself never runs; nothing is written)"; show_calls; fi
fresh
run_update --dry-run
if [ "$RC" = 0 ] && has "✓ rexume check — rexume is installed" && [ "$(count_calls "rexume --check --no-status")" = 1 ]; then
  ok "rexume: --dry-run reports an installed rexume"
else bad "rexume: --dry-run reports an installed rexume"; show_calls; fi

# --- 10: failures ------------------------------------------------------------------
fresh
STUB_FAIL="pi config packages --apply" run_update
if [ "$RC" = 1 ] && has "✗" && has "    stub failure for: pi config packages --apply" \
  && ! grep -Fxq "    noisy line 1" "$OUT" && has "earlier lines omitted" && grep -Eq '^Summary: .*1 failed' "$OUT"; then
  ok "failed step prints ✗ with an indented output tail and exits 1"
else bad "failed step prints ✗ with an indented output tail and exits 1"; fi

fresh
STUB_FAIL="pi config apply --apply" run_update
! called "pi config packages --apply" && [ "$(count_calls "pi config check")" = 0 ] && [ "$RC" = 1 ] \
  && ok "Pi packages/check are skipped after a failed apply" \
  || bad "Pi packages/check are skipped after a failed apply"

# --- 11: color only on a TTY and never with NO_COLOR ---------------------------------
fresh
pty_run() {
  (cd "$TMP/public" && STUB_LOG="$TMP/calls" STUB_UNAME=Darwin REX_BIN="$TMP/bin/rex" TERM=xterm \
    python3 "$TMP/pty-run.py" "$BASH" scripts/update.sh --dry-run) > "$OUT" 2>&1 < /dev/null
  RC=$?
}
# Run a command on a pseudo-terminal and copy its output (pty.spawn hangs at
# EOF on macOS Python 3.9, so read until EOF/EIO explicitly).
cat > "$TMP/pty-run.py" <<'PY' || die "pty helper"
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    sys.stdout.buffer.write(chunk)
sys.stdout.flush()
_, status = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
PY
pty_run
[ "$RC" = 0 ] && grep -q $'\033\[' "$OUT" && ok "color on a TTY" || bad "color on a TTY"
NO_COLOR=1 pty_run
[ "$RC" = 0 ] && has "Summary:" && ! grep -q $'\033\[' "$OUT" \
  && ok "NO_COLOR disables color on a TTY" || bad "NO_COLOR disables color on a TTY"

# --- 12: the real `dot` dispatches to update.sh --------------------------------------
"$ROOT/dot" update --help > "$OUT" 2>&1 && has "Usage: ./dot update" \
  && ok "./dot update dispatches to scripts/update.sh" || bad "./dot update dispatches to scripts/update.sh"
"$ROOT/dot" help > "$OUT" 2>&1 && has "update" && grep -Eq '^  update ' "$OUT" \
  && ok "./dot help lists update" || bad "./dot help lists update"

printf '\n== update tests: %d pass, %d fail ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
