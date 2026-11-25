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
#   - both decide and write under one lock, ~/.pi/.dotfiles-profiles.lock
#     (an atomic mkdir holding its owner's pid), so they can't interleave.
#     The lock is never taken over: one left by a dead owner must be removed
#     by hand. rexume supports only the default Pi root (~/.pi), so the lock
#     and rexume detection always use it, whatever PI_HOME says.
# No heredocs or here-strings here: bash 3.2 writes those to temp files, and
# `./dot rexume --dry-run` must write nothing.

DOTFILES_PROFILES_LOCK=""

# dotfiles_pi_work_profiles <pi-root>: every <pi-root> entry that is, or might
# be, a work Pi profile, one per line. Fails closed: names are matched
# case-insensitively (macOS volumes usually are, so AGENT-WORK counts), and any
# directory, symlink (dangling too) or file whose name starts with "agent"
# counts, except "agent" itself (the personal profile) and a plain
# agent-memory directory (not a symlink) with neither settings.json nor
# extensions, which is the VPS's memory data directory, not a profile.
dotfiles_pi_work_profiles() {
  local p lower
  for p in "$1"/*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    lower="$(printf '%s' "${p##*/}" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      agent) continue ;;
      agent*) ;;
      *) continue ;;
    esac
    if [ "$lower" = agent-memory ] && [ -d "$p" ] && [ ! -L "$p" ] \
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

# dotfiles_profiles_lock <who>: take ~/.pi/.dotfiles-profiles.lock, waiting up
# to DOTFILES_PROFILES_LOCK_TIMEOUT seconds (default 10) while a live owner
# holds it. Returns 0 when taken, 1 otherwise (with the reason on stderr,
# prefixed by <who>). Never takes a lock over: one whose recorded owner is gone
# is refused at once, for the user to remove by hand (two runs that both saw
# the dead owner could otherwise move each other's live lock). A lock without a
# readable pid may be mid-creation, so it is waited for, then refused.
# Release with dotfiles_profiles_unlock.
dotfiles_profiles_lock() {
  local who="$1" root="$HOME/.pi" lock="$HOME/.pi/.dotfiles-profiles.lock" limit deadline pid
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
          printf '%s: %s is stale: its owner (pid %s) is gone. Check that no ./dot rexume --apply or ./dot pi profiles --apply is running, then remove it by hand: rm -r %s. Nothing changed.\n' \
            "$who" "$lock" "$pid" "$lock" >&2
          return 1
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
