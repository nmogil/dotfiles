# shellcheck shell=bash
# pi-profiles-lock.sh — shared by scripts/setup-rexume.sh and
# scripts/setup-pi-profiles.sh. Sourcing it only defines functions.
#
# rexume must never be installed on a machine with a work Pi profile: its Pi
# extension would load there through the shared extensions directory, and
# rexume reopens Pi without PI_CODING_AGENT_DIR, so a work conversation would
# come back under the personal profile (docs/rexume.md). So:
#   - `./dot rexume --apply` refuses while any work profile exists;
#   - `./dot pi profiles --apply` refuses while rexume is installed;
#   - both decide and write under one lock, <pi-root>/.dotfiles-profiles.lock
#     (an atomic mkdir holding its owner's pid), so they can't interleave.
# No heredocs or here-strings here: bash 3.2 writes those to temp files, and
# `./dot rexume --dry-run` must write nothing.

DOTFILES_PROFILES_LOCK=""

# dotfiles_pi_work_profiles <pi-root>: every <pi-root>/agent-* entry that is,
# or might be, a Pi profile, one per line. Fails closed: any directory,
# symlink (dangling too) or file counts, except a plain agent-memory directory
# (not a symlink) with neither settings.json nor extensions, which is the
# VPS's memory data directory, not a profile.
dotfiles_pi_work_profiles() {
  local p
  for p in "$1"/agent-*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    if [ "${p##*/}" = agent-memory ] && [ -d "$p" ] && [ ! -L "$p" ] \
      && [ ! -e "$p/settings.json" ] && [ ! -L "$p/settings.json" ] \
      && [ ! -e "$p/extensions" ] && [ ! -L "$p/extensions" ]; then
      continue
    fi
    printf '%s\n' "$p"
  done
}

# dotfiles_rexume_trace <pi-personal-dir>: prints the first sign that rexume is
# installed (its Pi extension, binary, systemd unit, LaunchAgent, or a rexume
# on PATH); fails when there is none. Reads files only.
dotfiles_rexume_trace() {
  local cfg="${XDG_CONFIG_HOME:-}" f found
  case "$cfg" in /*) ;; *) cfg="$HOME/.config" ;; esac
  for f in "$1/extensions/rexume.ts" "$HOME/.pi/agent/extensions/rexume.ts" "$HOME/.local/bin/rexume" \
    "$cfg/systemd/user/rexume.service" "$HOME/Library/LaunchAgents/io.github.entwining.rexume.plist"; do
    if [ -e "$f" ] || [ -L "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  if found="$(command -v rexume 2>/dev/null)"; then printf '%s' "$found"; return 0; fi
  return 1
}

# A pid is alive unless that is provable: kill -0 can fail for another user's
# live process, so it is gone only if ps can run and doesn't list it.
_dotfiles_pid_alive() {
  kill -0 "$1" 2>/dev/null && return 0
  command -v ps >/dev/null 2>&1 || return 0
  ps -p "$1" >/dev/null 2>&1
}

_dotfiles_rename() { perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2" 2>/dev/null; }

# dotfiles_profiles_lock <pi-root> <who>: take the profiles lock, waiting up to
# DOTFILES_PROFILES_LOCK_TIMEOUT seconds (default 10). Returns 0 when taken,
# 1 otherwise (with the reason on stderr, prefixed by <who>). A lock whose
# recorded pid is gone is taken over; one without a readable pid is not (its
# owner may still be writing it). Release with dotfiles_profiles_unlock.
dotfiles_profiles_lock() {
  local root="$1" who="$2" lock="$1/.dotfiles-profiles.lock" limit deadline pid stale
  limit="${DOTFILES_PROFILES_LOCK_TIMEOUT:-10}"
  case "$limit" in ''|*[!0-9]*) limit=10 ;; esac
  mkdir -p "$root" || { printf '%s: could not create %s\n' "$who" "$root" >&2; return 1; }
  deadline=$(( $(date +%s) + limit ))
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      if printf '%s\n' "$$" > "$lock/pid"; then
        DOTFILES_PROFILES_LOCK="$lock"
        return 0
      fi
      rm -rf "$lock"
      printf '%s: could not write %s/pid\n' "$who" "$lock" >&2
      return 1
    fi
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        if ! _dotfiles_pid_alive "$pid"; then
          # Move the stale lock aside atomically, and delete it only if it is
          # still the dead owner's; otherwise put it back untouched.
          stale="$lock.stale.$$"
          if _dotfiles_rename "$lock" "$stale"; then
            if [ "$(cat "$stale/pid" 2>/dev/null || true)" = "$pid" ]; then
              rm -rf "$stale"
              continue
            fi
            _dotfiles_rename "$stale" "$lock" \
              || printf '%s: moved a live lock to %s and could not restore it; remove it once pid %s exits\n' \
                "$who" "$stale" "$(cat "$stale/pid" 2>/dev/null || echo unknown)" >&2
          fi
        fi ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf '%s: another ./dot rexume --apply or ./dot pi profiles --apply holds %s (pid %s); try again when it finishes. Nothing changed.\n' \
        "$who" "$lock" "${pid:-unknown}" >&2
      return 1
    fi
    sleep 1
  done
}

dotfiles_profiles_unlock() {
  if [ -n "$DOTFILES_PROFILES_LOCK" ] && [ "$(cat "$DOTFILES_PROFILES_LOCK/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$DOTFILES_PROFILES_LOCK"
  fi
  DOTFILES_PROFILES_LOCK=""
}
