#!/usr/bin/env bash
# local-env.sh — the optional, gitignored local configuration layer.
#
# Source this from setup/clone/doctor scripts. It is safe when no local config
# exists: callers fall back to portable, generic defaults. Local config lives
# OUTSIDE this repo so private values never get committed:
#
#   ${DOTFILES_LOCAL_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/local.env}
#
# See config/dotfiles/local.env.example for the documented keys. This file
# never prints the contents of local.env; callers should not echo secrets.

# Absolute path to the active local.env (may not exist).
dotfiles_local_env_path() {
  if [ -n "${DOTFILES_LOCAL_ENV:-}" ]; then
    printf '%s\n' "$DOTFILES_LOCAL_ENV"
  else
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/local.env"
  fi
}

# Source local.env if present. Returns 0 when loaded, 1 when absent.
# Preserves the caller's existing `allexport` (set -a) state.
load_local_env() {
  local f rc=0
  f="$(dotfiles_local_env_path)"
  [ -f "$f" ] || return 1
  local had_allexport=0
  case "$-" in *a*) had_allexport=1 ;; esac
  set -a
  # shellcheck disable=SC1090
  . "$f" || rc=$?
  [ "$had_allexport" -eq 1 ] || set +a
  return "$rc"
}

# A valid workstream bucket token is a single, safe path component: no slash,
# no dot/dotdot, no glob or shell metacharacters. Only [A-Za-z0-9_-].
dotfiles_is_valid_bucket_token() {
  local t="$1"
  [ -n "$t" ] || return 1
  case "$t" in
    *[!A-Za-z0-9_-]*) return 1 ;;  # rejects '/', '.', '..', globs, metachars
  esac
  return 0
}

# Load local.env (if any) then fill in portable defaults for anything the user
# did not set. Invalid bucket tokens are dropped with a warning. Call this once,
# early, in scripts that need the config layer.
dotfiles_load_config() {
  load_local_env || true
  : "${DOTFILES_REPO_BUCKETS:=personal ventures external}"
  : "${DOTFILES_PI_WORK_PROFILE_SLUG:=work}"
  if ! dotfiles_is_valid_bucket_token "$DOTFILES_PI_WORK_PROFILE_SLUG" \
    || [ "$DOTFILES_PI_WORK_PROFILE_SLUG" = "personal" ]; then
    printf 'local-env: invalid Pi work profile slug; using work\n' >&2
    DOTFILES_PI_WORK_PROFILE_SLUG="work"
  fi
  export DOTFILES_PI_WORK_PROFILE_SLUG
  local cleaned="" tok had_noglob=0
  case "$-" in *f*) had_noglob=1 ;; esac
  set -f  # word-split only; never pathname-expand bucket tokens
  for tok in $DOTFILES_REPO_BUCKETS; do
    if dotfiles_is_valid_bucket_token "$tok"; then
      cleaned="${cleaned:+$cleaned }$tok"
    else
      printf 'local-env: ignoring invalid bucket token: %s\n' "$tok" >&2
    fi
  done
  [ "$had_noglob" -eq 1 ] || set +f
  DOTFILES_REPO_BUCKETS="$cleaned"
  export DOTFILES_REPO_BUCKETS
}

# True if $1 is one of the configured workstream buckets.
dotfiles_is_bucket() {
  local candidate="$1" b had_noglob=0 rc=1
  case "$-" in *f*) had_noglob=1 ;; esac
  set -f
  for b in ${DOTFILES_REPO_BUCKETS:-}; do
    [ "$b" = "$candidate" ] && { rc=0; break; }
  done
  [ "$had_noglob" -eq 1 ] || set +f
  return "$rc"
}

# If local.env supplied a git identity, write it to an included, gitignored
# local git config (~/.config/git/local.gitconfig — see .gitconfig [include]).
# Rejects control characters (CR/LF, etc.) to prevent config-line injection and
# writes the file with owner-only permissions.
# Returns: 0 wrote identity, 1 no identity configured, 2 invalid identity.
dotfiles_apply_git_identity() {
  local name="${DOTFILES_GIT_NAME:-}" email="${DOTFILES_GIT_EMAIL:-}"
  [ -n "$name$email" ] || return 1
  case "$name$email" in
    *[[:cntrl:]]*)
      printf 'local-env: git identity contains control characters; refusing to write\n' >&2
      return 2 ;;
  esac
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/git"
  mkdir -p "$dir"
  local f="$dir/local.gitconfig" old_umask
  old_umask="$(umask)"
  umask 077
  : > "$f"
  if [ -n "$name" ]; then
    git config --file "$f" user.name "$name" || { umask "$old_umask"; return 2; }
  fi
  if [ -n "$email" ]; then
    git config --file "$f" user.email "$email" || { umask "$old_umask"; return 2; }
  fi
  umask "$old_umask"
  chmod 600 "$f" 2>/dev/null || true
  return 0
}
