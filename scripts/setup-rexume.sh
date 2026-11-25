#!/usr/bin/env bash
# setup-rexume.sh — install/check rexume, the daemon that reopens agent
# conversations in Rex panes after a Rex server restart and returns worker
# results to orchestrators (https://github.com/Entwining/rexume, MIT).
# See docs/rexume.md.
#
#   Binary. macOS (Apple Silicon, macOS 15+): Homebrew (entwining/tap/rexume,
#          opt-in: not in the Brewfile); --apply only installs it when missing.
#          Linux (x86_64): the release pinned in config/rexume/release.pins;
#          the archive must match its sha256 AND pass `gh attestation verify`
#          against the pinned signer workflow, and the binary inside must match
#          its sha256, before ~/.local/bin/rexume is touched.
#   Hooks and daemon. `rexume install`, run only after a read-only probe shows
#          the Rex server takes a block ID where a session goes (Rex
#          0.1.0-preview.23+), with PI_CODING_AGENT_DIR removed from its
#          environment so it writes the Pi extension to the personal profile
#          (~/.pi/agent) only. It refuses on any machine with a work Pi
#          profile (any ~/.pi/agent-* entry but a plain agent-memory data
#          directory; checked again right before `rexume install`): Pi profiles
#          share their extensions directory, and rexume reopens Pi without
#          PI_CODING_AGENT_DIR, so a work conversation would come back under
#          the personal profile. It also refuses a personal rexume.ts or
#          extensions symlink that install would write through. --apply holds
#          the profiles lock that `./dot pi profiles --apply` also takes, so
#          the two never interleave (scripts/lib/pi-profiles-lock.sh).
#
# Checks are read-only: they run rexume only as `rexume status`, and only a
# verified binary (`--check --no-status` never runs it, for `./dot update
# --dry-run`: status opens state.db read-only, which SQLite may still give a
# -wal/-shm file); ask Homebrew only for `brew --cellar`; and query systemd or
# launchd without changing anything. --dry-run writes nothing and does no
# network (no heredocs or here-strings: bash 3.2 writes them to temp files).
# Daemon-manager and status calls are bounded (DOTFILES_REXUME_CALL_TIMEOUT,
# default 10s). Nothing here stops or restarts the Rex server or types into panes.
#
# Exit codes: 0 ok; 1 problem (differs, failed, refused); 2 usage;
# 3 (--check only) rexume is not installed at all.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="$ROOT/config/rexume/release.pins"
LABEL=io.github.entwining.rexume

usage() {
  cat <<'EOF'
usage: ./dot rexume [--dry-run | --check [--no-status] | --apply [--force]]
  --dry-run       report what --apply would do (default; changes nothing, no network)
  --check         exit 0 if installed as expected, 3 if not installed at all, 1 otherwise
  --check --no-status
                  the same, but never runs rexume (skips `rexume status`, whose
                  read-only SQLite open can still create state.db-wal/-shm)
  --apply         install rexume if missing (Mac: Homebrew; Linux: pinned, attested
                  release), probe the Rex server, then run `rexume install` (hooks,
                  personal Pi extension, daemon) without PI_CODING_AGENT_DIR
  --apply --force Linux only: back up a differing ~/.local/bin/rexume, then install the pin
EOF
}

MODE=--dry-run FORCE=0 NO_STATUS=0
case "$#:${1:-}:${2:-}" in
  0::) ;;
  1:--dry-run:|1:--check:|1:--apply:) MODE="$1" ;;
  2:--apply:--force) MODE=--apply FORCE=1 ;;
  2:--check:--no-status) MODE=--check NO_STATUS=1 ;;
  1:-h:|1:--help:) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

# shellcheck source=scripts/lib/pinned-release.sh
. "$ROOT/scripts/lib/pinned-release.sh"
# shellcheck source=scripts/lib/pi-profiles-lock.sh
. "$ROOT/scripts/lib/pi-profiles-lock.sh"
PR_NAME=rexume PR_PINS="$PINS" PR_DOC=docs/rexume.md
PR_VERIFY_NOTE="sha256- and GitHub-attestation-verified"
RX_TMP=""
cleanup() {
  dotfiles_profiles_unlock
  pr_cleanup
  if [ -n "$RX_TMP" ]; then rm -rf -- "$RX_TMP"; fi
}
trap cleanup EXIT

say() { pr_say "$@"; }
die() { pr_die "$@"; }

OS="$(uname -s)"
PI_DIR="$HOME/.pi/agent"
PI_EXT="$PI_DIR/extensions/rexume.ts"
REXUME_BIN=""   # set only to a verified binary: Homebrew's, or ~/.local/bin/rexume matching the pin
CALL_LIMIT="${DOTFILES_REXUME_CALL_TIMEOUT:-10}"
case "$CALL_LIMIT" in ''|*[!0-9]*|0) CALL_LIMIT=10 ;; esac

# ---------------------------------------------------------------- platform
mac_setup() {
  FORMULA="$(pr_pin REXUME_BREW_FORMULA)" || exit 1
  case "$FORMULA" in */*/rexume) ;; *) die "unexpected REXUME_BREW_FORMULA in $PINS" ;; esac
  [ "$(uname -m)" = arm64 ] || die "no macOS rexume build for $(uname -m) (upstream ships Apple Silicon only, macOS 15+)"
  local ver major
  ver="$(sw_vers -productVersion 2>/dev/null || true)"
  major="${ver%%.*}"
  case "$major" in
    ''|*[!0-9]*) die "can't read the macOS version (sw_vers -productVersion); rexume needs macOS 15 or later" ;;
  esac
  [ "$major" -ge 15 ] || die "rexume needs macOS 15 or later (this is macOS $ver); upstream's Homebrew formula requires it"
}

linux_setup() {
  local arch
  arch="$(uname -m)"
  [ "$arch" = x86_64 ] || die "no pinned rexume build for Linux $arch (only x86_64 is pinned; see docs/rexume.md)"
  pr_load_linux_pins REXUME 'rexume-[0-9.]+-x86_64-unknown-linux-musl\.tar\.gz'
  MEMBER="$(pr_pin REXUME_LINUX_X86_64_BINARY_MEMBER)" || exit 1
  [ "$MEMBER" = "${PR_ARCHIVE%.tar.gz}/bin/rexume" ] \
    || die "bad REXUME_LINUX_X86_64_BINARY_MEMBER in $PINS (expected ${PR_ARCHIVE%.tar.gz}/bin/rexume)"
  ATTEST_REPO="$(pr_pin REXUME_ATTESTATION_REPO)" || exit 1
  ATTEST_WORKFLOW="$(pr_pin REXUME_ATTESTATION_SIGNER_WORKFLOW)" || exit 1
  printf '%s\n' "$ATTEST_REPO" | grep -Eqx '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' \
    || die "bad REXUME_ATTESTATION_REPO in $PINS"
  case "$ATTEST_WORKFLOW" in
    "$ATTEST_REPO"/.github/workflows/*) ;;
    *) die "bad REXUME_ATTESTATION_SIGNER_WORKFLOW in $PINS (must be in $ATTEST_REPO)" ;;
  esac
  printf '%s\n' "${ATTEST_WORKFLOW#"$ATTEST_REPO"/.github/workflows/}" | grep -Eqx '[A-Za-z0-9_.-]+\.ya?ml' \
    || die "bad REXUME_ATTESTATION_SIGNER_WORKFLOW in $PINS"
}

# verify_attestation <archive>: GitHub's build provenance for the archive must
# come from the pinned repository's pinned release workflow. Upstream requires
# this before the binary goes on PATH; without gh, nothing is installed.
verify_attestation() {
  local out
  command -v gh >/dev/null 2>&1 \
    || { say "rexume: gh (the GitHub CLI) is required to verify the release's GitHub attestation" >&2; return 1; }
  if ! out="$(gh attestation verify "$1" --repo "$ATTEST_REPO" --signer-workflow "$ATTEST_WORKFLOW" 2>&1)"; then
    say "rexume: gh attestation verify failed for ${1##*/} (signer workflow $ATTEST_WORKFLOW):" >&2
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /' >&2
    return 1
  fi
  say "verified the GitHub attestation of ${1##*/} (signer workflow $ATTEST_WORKFLOW)"
}

# ---------------------------------------------------------------- state (read-only)
job_file() {
  local cfg="${XDG_CONFIG_HOME:-}"
  if [ "$OS" = Darwin ]; then printf '%s' "$HOME/Library/LaunchAgents/$LABEL.plist"; return; fi
  case "$cfg" in /*) ;; *) cfg="$HOME/.config" ;; esac
  printf '%s' "$cfg/systemd/user/rexume.service"
}

# bounded <cmd...>: run cmd for at most CALL_LIMIT seconds (macOS has no
# timeout(1)). Returns its status; one above 128 means it was killed.
bounded() {
  local pid watcher rc=0
  "$@" &
  pid=$!
  ( n=0
    while [ "$n" -lt "$CALL_LIMIT" ]; do sleep 1; n=$((n + 1)); done
    kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}

# daemon_active: 0 when the job runs; otherwise 1 with DAEMON_WHY set.
daemon_active() {
  local out rc=0
  DAEMON_WHY=""
  if [ "$OS" = Darwin ]; then
    if ! command -v launchctl >/dev/null 2>&1; then
      DAEMON_WHY="launchctl is not on PATH; can't tell whether the rexume daemon is active"; return 1
    fi
    out="$(bounded launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null)" || rc=$?
    if [ "$rc" -gt 128 ]; then
      DAEMON_WHY="launchctl print gui/$(id -u)/$LABEL timed out after ${CALL_LIMIT}s"; return 1
    fi
    if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -Eq '^[[:space:]]*state = running[[:space:]]*$'; then
      return 0
    fi
    DAEMON_WHY="the rexume daemon is not active (launchctl print gui/$(id -u)/$LABEL)"; return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    DAEMON_WHY="systemctl is not on PATH; can't tell whether the rexume daemon is active"; return 1
  fi
  bounded systemctl --user is-active --quiet rexume || rc=$?
  case "$rc" in
    0) return 0 ;;
    1[3-9][0-9]|129|2[0-9][0-9]) DAEMON_WHY="systemctl --user is-active rexume timed out after ${CALL_LIMIT}s" ;;
    *) DAEMON_WHY="the rexume daemon is not active (systemctl --user status rexume)" ;;
  esac
  return 1
}

# status_call: run `rexume status` (bounded, without PI_CODING_AGENT_DIR);
# STATUS_OUT gets its stdout and stderr. Fails with STATUS_WHY set.
status_call() {
  local rc=0
  STATUS_WHY=""
  STATUS_OUT="$(bounded env -u PI_CODING_AGENT_DIR "$REXUME_BIN" status 2>&1)" || rc=$?
  [ "$rc" != 0 ] || return 0
  if [ "$rc" -gt 128 ]; then STATUS_WHY="rexume status timed out after ${CALL_LIMIT}s"
  else STATUS_WHY="rexume status failed: $(printf '%s\n' "$STATUS_OUT" | head -n 1)"
  fi
  return 1
}

# dev_ino <path>: device:inode of what <path> resolves to; fails when it
# doesn't resolve (BSD stat -L would describe a dangling link itself).
dev_ino() {
  [ -e "$1" ] || return 1
  stat -L -c '%d:%i' -- "$1" 2>/dev/null || stat -L -f '%d:%i' -- "$1" 2>/dev/null
}

# work_profiles: sets WORK_PROFILES to the ~/.pi/agent-* entries that are, or
# might be, Pi profiles (scripts/lib/pi-profiles-lock.sh), space-separated.
work_profiles() {
  WORK_PROFILES="$(dotfiles_pi_work_profiles "$HOME/.pi" | tr '\n' ' ')"
  WORK_PROFILES="${WORK_PROFILES% }"
}
WP_MSG="rexume can't be installed on a machine with a work Pi profile"
wp_refusal() {
  printf '%s (%s) until Pi profiles stop sharing extensions: its extension would load in the work profile, and rexume reopens Pi without PI_CODING_AGENT_DIR. See docs/rexume.md (work profile).' \
    "$WP_MSG" "$WORK_PROFILES"
}

# personal_issues <strict 0|1>: sets PI_ISSUES for personal-profile paths
# rexume install would write through: a symlink at rexume.ts and, with strict,
# a ~/.pi/agent or ~/.pi/agent/extensions symlink that doesn't resolve (install
# would create its target).
personal_issues() {
  PI_ISSUES=""
  if [ -L "$PI_EXT" ]; then
    PI_ISSUES="$PI_EXT is a symlink ($(readlink "$PI_EXT")); rexume install would write through it"
  fi
  [ "$1" = 1 ] || return 0
  if [ -L "$PI_DIR" ] && [ ! -e "$PI_DIR" ]; then
    PI_ISSUES="${PI_ISSUES:+$PI_ISSUES; }$PI_DIR is a symlink that doesn't resolve; rexume install could create its target"
  fi
  if [ -L "$PI_DIR/extensions" ] && [ ! -e "$PI_DIR/extensions" ]; then
    PI_ISSUES="${PI_ISSUES:+$PI_ISSUES; }$PI_DIR/extensions is a symlink that doesn't resolve ($(readlink "$PI_DIR/extensions")); rexume install would create its target"
  fi
}

# binary_status: BIN_RC 0 (verified; REXUME_BIN set), 3 (absent), 1 (problem). Prints why.
binary_status() {
  local other
  BIN_RC=0
  if [ "$OS" = Darwin ]; then
    pr_brew_classify "$FORMULA" || BIN_RC=$?
    if [ "$BIN_RC" = 0 ]; then REXUME_BIN="$PR_BREW_BIN"; fi
  else
    pr_linux_check || BIN_RC=$?
    if [ "$BIN_RC" = 0 ]; then REXUME_BIN="$PR_DST"; fi
    if [ "$BIN_RC" = 3 ] && other="$(command -v rexume 2>/dev/null)"; then
      say "rexume at $other is not the pinned install at $PR_DST; remove it or fix PATH" >&2
      BIN_RC=1
    fi
  fi
}

# ---------------------------------------------------------------- --check
do_check() {
  local any=0 problems="" hooks job
  binary_status
  [ "$BIN_RC" = 3 ] || any=1
  [ "$BIN_RC" != 1 ] || problems="${problems}
  the rexume binary is not as expected (see above)"
  [ "$BIN_RC" != 3 ] || problems="${problems}
  the rexume binary is not installed"
  if [ -e "$PI_EXT" ] || [ -L "$PI_EXT" ]; then any=1; fi
  if [ ! -e "$PI_EXT" ]; then problems="${problems}
  $PI_EXT is missing (rexume install writes it when $PI_DIR exists)"
  fi
  personal_issues 0
  if [ -n "$PI_ISSUES" ]; then problems="${problems}
  $PI_ISSUES"
  fi
  job="$(job_file)"
  [ ! -e "$job" ] || any=1
  if daemon_active; then any=1
  else problems="${problems}
  $DAEMON_WHY"
  fi
  if [ "$any" = 0 ]; then
    say "rexume is not installed (./dot rexume --apply)"
    return 3
  fi
  work_profiles
  if [ -n "$WORK_PROFILES" ]; then problems="${problems}
  a work Pi profile exists ($WORK_PROFILES); rexume must not be installed alongside one (see docs/rexume.md, work profile)"
  fi
  if [ -z "$problems" ] && [ -n "$REXUME_BIN" ] && [ "$NO_STATUS" = 1 ]; then
    say "rexume is installed: binary, daemon active, personal Pi extension; no work Pi profile on this machine (rexume status not run)."
    return 0
  fi
  if [ -z "$problems" ] && [ -n "$REXUME_BIN" ]; then
    # The only rexume run in a check: status reads the state database and settings.
    if status_call; then
      hooks="$(printf '%s\n' "$STATUS_OUT" | tr -d ' \t\n' | grep -oE '"claude_hooks_missing":(null|\[[^]]*\])' | sed 's/^"claude_hooks_missing"://' || true)"
      case "$hooks" in
        '[]') ;;
        null) problems="${problems}
  rexume status: claude_hooks_missing is null: it couldn't read the Claude Code settings (or CLAUDE_CONFIG_DIR)" ;;
        '') problems="${problems}
  rexume status gave no claude_hooks_missing; not a status response this installer understands" ;;
        *) problems="${problems}
  rexume status: Claude Code hooks missing from settings (claude_hooks_missing): $hooks (the daemon adds them when it starts)" ;;
      esac
    else
      problems="${problems}
  $STATUS_WHY"
    fi
  fi
  if [ -n "$problems" ]; then
    say "rexume is not fully installed:$problems" >&2
    return 1
  fi
  say "rexume is installed: binary, daemon active, personal Pi extension; no work Pi profile on this machine."
  return 0
}

# ---------------------------------------------------------------- --apply / --dry-run
# The Rex server must take a pane's block ID where a session goes (Rex
# 0.1.0-preview.23+); rexume's hooks and skill rely on it. Read-only listings,
# with --autostart=false so the CLI never starts a server itself.
rex_probe() {
  local rex sessions sids sid blocks bid="" err
  rex="$(PATH="$INSTALL_PATH"; command -v rex 2>/dev/null || true)"
  if [ -z "$rex" ]; then
    say "rexume: rex (the Rex CLI) is not on PATH; rexume install needs it." >&2
    return 1
  fi
  if ! sessions="$("$rex" --autostart=false ls --json 2>/dev/null </dev/null)"; then
    say "rexume: couldn't list Rex sessions with $rex; is the Rex server running?" >&2
    return 1
  fi
  sids="$(printf '%s\n' "$sessions" | grep -oE '"session_id" *: *"session:[A-Za-z0-9-]+"' | sed -E 's/.*"(session:[A-Za-z0-9-]+)"$/\1/' || true)"
  for sid in $sids; do
    blocks="$("$rex" --autostart=false block ls --json -s "$sid" 2>/dev/null </dev/null)" || continue
    bid="$(printf '%s\n' "$blocks" | grep -oE '"block_id" *: *"block:[A-Za-z0-9-]+"' | sed -E 's/.*"(block:[A-Za-z0-9-]+)"$/\1/' | head -n 1 || true)"
    [ -z "$bid" ] || break
  done
  if [ -z "$bid" ]; then
    say "rexume: the Rex server has no pane to probe with, so I can't verify that it takes a block ID where a session goes (Rex 0.1.0-preview.23+). Open any pane and rerun." >&2
    return 1
  fi
  if ! err="$("$rex" --autostart=false block ls --json -s "$bid" 2>&1 >/dev/null </dev/null)"; then
    say "rexume: the Rex server refuses a block ID where a session goes ($(printf '%s\n' "$err" | head -n 1))." >&2
    say "rexume: it is older than Rex 0.1.0-preview.23, where rexume's hooks would record nothing to reopen. Upgrade the Rex server and its CLI first (Linux: rex-safe-upgrade; Mac: update the Rex app), then rerun." >&2
    return 1
  fi
  say "Rex server takes a block ID where a session goes (Rex 0.1.0-preview.23 or later)."
}

# summarize_install <file>: rexume install's JSON summary as one line of
# field=value, with the non-null notes after it. (No heredoc: see the header.)
summarize_install() {
  local pairs rest line key val items="" notes="" nl='
'
  pairs="$(tr '\n\t' '  ' < "$1" | grep -oE '"[a-z_]+" *: *("([^"\\]|\\.)*"|null|true|false|-?[0-9]+)' || true)"
  if [ -z "$pairs" ]; then
    say "rexume install printed:"; sed 's/^/  /' "$1"; return 0
  fi
  rest="$pairs$nl"
  while [ -n "$rest" ]; do
    line="${rest%%"$nl"*}"
    rest="${rest#*"$nl"}"
    key="$(printf '%s\n' "$line" | sed -E 's/^"([a-z_]+)".*/\1/')"
    val="$(printf '%s\n' "$line" | sed -E 's/^"[a-z_]+" *: *//; s/^"(.*)"$/\1/')"
    case "$key" in
      version|*_label|*_name) continue ;;
      *_note)
        if [ "$val" != null ]; then notes="$notes
  ${key%_note}: $val"; fi
        continue ;;
    esac
    items="${items:+$items, }$key=$val"
  done
  say "rexume install: $items"
  if [ -n "$notes" ]; then say "notes:$notes"; fi
}

run_install() {
  RX_TMP="$(mktemp -d)" || die "couldn't make a temporary directory"
  say "running: env -u PI_CODING_AGENT_DIR $REXUME_BIN install (PATH as below, recorded for the daemon)"
  say "  PATH=$INSTALL_PATH"
  if ! env -u PI_CODING_AGENT_DIR PATH="$INSTALL_PATH" "$REXUME_BIN" install > "$RX_TMP/out" 2> "$RX_TMP/err"; then
    sed 's/^/  /' "$RX_TMP/out" "$RX_TMP/err" >&2
    die "rexume install failed; see above and docs/rexume.md"
  fi
  if [ -s "$RX_TMP/err" ]; then sed 's/^/  /' "$RX_TMP/err"; fi
  summarize_install "$RX_TMP/out"
}

# path_conflict <PATH>: prints the first executable rexume on <PATH> ahead of
# ~/.local/bin (anywhere, when ~/.local/bin isn't on it). Linux only. Splits
# PATH with parameter expansion: this runs in --dry-run, which writes nothing.
path_conflict() {
  local rest="$1:" dir
  while [ -n "$rest" ]; do
    dir="${rest%%:*}"
    rest="${rest#*:}"
    [ -n "$dir" ] || dir=.
    if [ "$dir" = "$PR_DIR" ] || [ "$dir" = "$PR_DIR/" ] \
      || { [ -d "$PR_DIR" ] && [ "$(dev_ino "$dir" || true)" = "$(dev_ino "$PR_DIR" || true)" ]; }; then
      return 1
    fi
    if [ -f "$dir/rexume" ] && [ -x "$dir/rexume" ]; then printf '%s' "$dir/rexume"; return 0; fi
  done
  return 1
}

# wait_ready: after rexume install, wait until the daemon runs and `rexume
# status` succeeds (it fails until the daemon creates its database), up to
# DOTFILES_REXUME_READY_TIMEOUT seconds of elapsed time (default 20). Each
# call is itself bounded.
wait_ready() {
  local limit="${DOTFILES_REXUME_READY_TIMEOUT:-20}" deadline
  case "$limit" in ''|*[!0-9]*) limit=20 ;; esac
  deadline=$(( $(date +%s) + limit ))
  READY_WHY=""
  while :; do
    if daemon_active; then
      if status_call; then return 0; fi
      READY_WHY="$STATUS_WHY"
    else
      READY_WHY="$DAEMON_WHY"
    fi
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 1
  done
}

do_apply() {
  local rc=0 need_brew=0 found preview
  # 1. Take the profiles lock (shared with ./dot pi profiles --apply) for the
  #    whole check-and-write; --dry-run writes nothing, so it takes none.
  if [ "$MODE" = --apply ]; then
    dotfiles_profiles_lock "$HOME/.pi" rexume || exit 1
  fi

  # 2. No rexume on a machine with a work Pi profile (fail closed).
  work_profiles
  if [ -n "$WORK_PROFILES" ]; then
    if [ "$MODE" = --dry-run ]; then
      say "--apply would refuse: $(wp_refusal)"
      return 0
    fi
    die "refusing: $(wp_refusal) Nothing changed."
  fi
  personal_issues 1
  if [ -n "$PI_ISSUES" ]; then
    if [ "$MODE" = --dry-run ]; then say "--apply would refuse: $PI_ISSUES"; return 0; fi
    die "refusing: $PI_ISSUES. Nothing changed."
  fi

  # 3. What is installed now (read-only).
  if [ "$OS" = Darwin ]; then
    pr_brew_classify "$FORMULA" || rc=$?
    case "$rc" in
      0) REXUME_BIN="$PR_BREW_BIN" ;;
      3) need_brew=1 ;;
      *) return 1 ;;
    esac
  fi

  # 4. The PATH rexume install records for the daemon. Its hooks run `rexume`
  #    by name, so on Linux ~/.local/bin must be on it.
  INSTALL_PATH="$PATH"
  if [ "$OS" = Linux ]; then
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) INSTALL_PATH="$HOME/.local/bin:$PATH" ;; esac
  fi

  # 5. Another rexume that agent runtimes (or the daemon) would run instead:
  #    the hooks run `rexume` by name on the caller's PATH. (macOS: step 3.)
  if [ "$OS" = Linux ] && found="$(path_conflict "$PATH")"; then
    die "$found comes before $PR_DIR/rexume on PATH (or $PR_DIR isn't on PATH); rexume's hooks run rexume by name. Remove it or fix PATH; nothing changed."
  fi

  if [ "$MODE" = --dry-run ]; then
    if [ "$OS" = Darwin ]; then
      preview="Homebrew's bin/rexume"
      if [ -n "${PR_BREW_CELLAR:-}" ]; then preview="$(dirname "$PR_BREW_CELLAR")/bin/rexume"; fi
      if [ "$need_brew" = 1 ]; then say "would run: brew install $FORMULA"; fi
    else
      preview="$PR_DST"
      pr_linux_apply --dry-run "$FORCE" "$MEMBER"
    fi
    say "would check (read-only) that the Rex server takes a block ID where a session goes (Rex 0.1.0-preview.23+)"
    say "would run: env -u PI_CODING_AGENT_DIR ${REXUME_BIN:-$preview} install (hooks, personal Pi extension, daemon; PATH=$INSTALL_PATH)"
    return 0
  fi

  # 6. Preflight before anything is installed.
  if [ "$OS" = Linux ]; then
    [ -n "${XDG_RUNTIME_DIR:-}" ] \
      || die "XDG_RUNTIME_DIR is not set, so rexume install can't find the Rex server or the systemd user manager. Run this from a login session; nothing changed."
    command -v systemctl >/dev/null 2>&1 \
      || die "systemctl is not on PATH; rexume runs as a systemd user service. Nothing changed."
  else
    command -v launchctl >/dev/null 2>&1 || die "launchctl is not on PATH; rexume runs as a LaunchAgent. Nothing changed."
  fi
  rex_probe || die "not running rexume install; nothing changed."

  # 7. The binary.
  if [ "$OS" = Darwin ]; then
    if [ "$need_brew" = 1 ]; then
      command -v brew >/dev/null 2>&1 || die "Homebrew is required on macOS (./dot setup mac)"
      brew install "$FORMULA" || die "brew install $FORMULA failed"
      rc=0; pr_brew_classify "$FORMULA" || rc=$?
      [ "$rc" = 0 ] || die "rexume isn't usable from Homebrew after brew install; not running rexume install"
      REXUME_BIN="$PR_BREW_BIN"
    fi
  else
    pr_dst_state
    if [ "$PR_STATE" = missing ] || { [ "$PR_STATE" = differs ] && [ "$FORCE" = 1 ]; }; then
      command -v gh >/dev/null 2>&1 \
        || die "gh (the GitHub CLI) is required to verify the release's GitHub attestation; nothing installed"
    fi
    pr_linux_apply --apply "$FORCE" "$MEMBER" verify_attestation
    REXUME_BIN="$PR_DST"
    found="$(PATH="$INSTALL_PATH"; command -v rexume 2>/dev/null || true)"
    if [ "$(pr_resolve "$found" || true)" != "$(pr_resolve "$PR_DST" || true)" ]; then
      die "$found comes before $PR_DST on PATH; rexume's hooks run rexume by name. Remove it or fix PATH; not running rexume install."
    fi
  fi

  # 8. Hooks, extensions, daemon. The profile checks run again right before:
  #    the lock keeps ./dot pi profiles out, but not a hand-made profile.
  work_profiles
  if [ -n "$WORK_PROFILES" ]; then die "refusing to run rexume install: $(wp_refusal) (It appeared during this run.)"; fi
  personal_issues 1
  if [ -n "$PI_ISSUES" ]; then die "refusing to run rexume install: $PI_ISSUES (changed during this run)."; fi
  run_install

  # 9. Wait (bounded) for the daemon, then check everything.
  if [ "$OS" = Linux ] && [ "$INSTALL_PATH" != "$PATH" ]; then
    say "note: $HOME/.local/bin is not on this shell's PATH (.zshrc adds it); it was added for rexume install."
  fi
  if ! wait_ready; then
    say "rexume: the rexume daemon is not ready after ${DOTFILES_REXUME_READY_TIMEOUT:-20}s: $READY_WHY" >&2
  fi
  rc=0; do_check || rc=$?
  return "$rc"
}

# ---------------------------------------------------------------- main
case "$OS" in
  Darwin) [ "$FORCE" = 0 ] || { usage >&2; exit 2; }; mac_setup ;;
  Linux) linux_setup ;;
  *) die "unsupported OS $OS" ;;
esac
case "$MODE" in
  --check) do_check ;;
  *) do_apply ;;
esac
exit 0
