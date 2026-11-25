#!/usr/bin/env bash
# pi-cli.sh — shared Pi CLI checks for the bash scripts (dot, update.sh, the
# Pi installers). Defines a constant and functions only; no side effects at
# source time. Works under macOS /bin/bash 3.2 (no sort -V, no associative arrays).
#
# Pi floats to the latest release (`./dot update` runs `pi update --self`); the
# dotfiles only require AT LEAST this version. The private baseline manifest
# and scaffold carry their own minimums, checked the same way (Python:
# scripts/lib/pi_version.py).

# shellcheck disable=SC2034 # used by the scripts that source this file
PI_MIN_VERSION="1.6.0"
PI_PACKAGE="@earendil-works/pi-coding-agent"

# Directory of this file (for pi_version.py), resolved when sourced.
PI_CLI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# pi_version_at_least <installed> <minimum>: true when both are x.y.z release
# versions (1-6 ASCII digits per component — the same grammar as
# pi_version.py) and installed >= minimum, compared numerically (1.10.0 >
# 1.9.0). Anything else (prereleases, "v1.6.0", "", oversized) is false.
pi_version_at_least() {
  local d='[0123456789]' re a1 a2 a3 b1 b2 b3
  re="^($d{1,6})\\.($d{1,6})\\.($d{1,6})\$"
  [[ "$1" =~ $re ]] || return 1
  a1=$((10#${BASH_REMATCH[1]})) a2=$((10#${BASH_REMATCH[2]})) a3=$((10#${BASH_REMATCH[3]}))
  [[ "$2" =~ $re ]] || return 1
  b1=$((10#${BASH_REMATCH[1]})) b2=$((10#${BASH_REMATCH[2]})) b3=$((10#${BASH_REMATCH[3]}))
  [ "$a1" -eq "$b1" ] || { [ "$a1" -gt "$b1" ]; return; }
  [ "$a2" -eq "$b2" ] || { [ "$a2" -gt "$b2" ]; return; }
  [ "$a3" -ge "$b3" ]
}

# pi_npm_version <absolute-pi-path>: read the installed Pi version from the
# package.json of a supported global npm install — WITHOUT launching Pi (its
# entry point can write even for --version). The path must be absolute and
# live in <prefix>/bin, resolving to <prefix>/lib/node_modules/<package>/dist/
# [bundle/]cli.js; project-local, pnpm, and Vite+ installs are refused (they
# break runtime imports used by Pi extensions). Callers run this same path.
# Sets PI_NPM_VERSION, or PI_NPM_PROBLEM (a reason). Returns 0 version read,
# 1 not a supported global npm install, 2 install found but its version is
# unavailable (or python3 is missing).
PI_NPM_VERSION="" PI_NPM_PROBLEM=""
pi_npm_version() {
  local out rc=0
  PI_NPM_VERSION="" PI_NPM_PROBLEM=""
  out="$(python3 -B "$PI_CLI_LIB_DIR/pi_version.py" installed-version "$1" 2>&1 < /dev/null)" || rc=$?
  case "$rc" in
    0) PI_NPM_VERSION="$out"; return 0 ;;
    3) PI_NPM_PROBLEM="$out"; return 1 ;;
    4) PI_NPM_PROBLEM="$out"; return 2 ;;
    *) PI_NPM_PROBLEM="could not run python3 to read the Pi version${out:+: $out}"; return 2 ;;
  esac
}

# pi_too_old_hint <installed> <minimum>: the one message for a Pi that fails
# pi_version_at_least.
pi_too_old_hint() {
  if pi_version_at_least "$1" 0.0.0; then
    printf 'Pi %s is older than the minimum %s' "$1" "$2"
  else
    printf 'Pi version %s is not a release version (minimum %s)' "'${1:-unknown}'" "$2"
  fi
  printf '; run pi update --self (or ./dot update)'
}
