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

# pi_version_at_least <installed> <minimum>: true when both are numeric x.y.z
# release versions and installed >= minimum (compared numerically, so
# 1.10.0 > 1.9.0). Anything unparsable (prereleases, "v1.6.0", "") is false.
pi_version_at_least() {
  local re='^([0-9]+)\.([0-9]+)\.([0-9]+)$' a1 a2 a3 b1 b2 b3
  [[ "$1" =~ $re ]] || return 1
  a1=$((10#${BASH_REMATCH[1]})) a2=$((10#${BASH_REMATCH[2]})) a3=$((10#${BASH_REMATCH[3]}))
  [[ "$2" =~ $re ]] || return 1
  b1=$((10#${BASH_REMATCH[1]})) b2=$((10#${BASH_REMATCH[2]})) b3=$((10#${BASH_REMATCH[3]}))
  [ "$a1" -eq "$b1" ] || { [ "$a1" -gt "$b1" ]; return; }
  [ "$a2" -eq "$b2" ] || { [ "$a2" -gt "$b2" ]; return; }
  [ "$a3" -ge "$b3" ]
}

# pi_uses_npm_layout <pi-path>: true when <pi-path> resolves into npm's global
# package layout. The Vite+ global layout breaks runtime imports used by Pi
# extensions, so only this layout is supported. Needs node to resolve symlinks.
pi_uses_npm_layout() {
  local resolved
  command -v node >/dev/null 2>&1 || return 1
  resolved="$(node -e 'const fs = require("node:fs"); try { process.stdout.write(fs.realpathSync(process.argv[1])); } catch { process.exit(1); }' "$1" 2>/dev/null || true)"
  case "$resolved" in
    */node_modules/@earendil-works/pi-coding-agent/dist/cli.js|*/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js) return 0 ;;
    *) return 1 ;;
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
