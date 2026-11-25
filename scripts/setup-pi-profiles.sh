#!/usr/bin/env bash
# setup-pi-profiles.sh — prepare separate personal and work Pi credential
# profiles without copying auth, sessions, MCP credentials, or caches.
set -euo pipefail

script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(CDPATH='' cd -P -- "$(dirname -- "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  CDPATH='' cd -P -- "$(dirname -- "$src")" && pwd
}

ROOT="$(CDPATH='' cd -- "$(script_dir)/.." && pwd)"
# shellcheck source=lib/local-env.sh
. "$ROOT/scripts/lib/local-env.sh"
# shellcheck source=lib/pi-profiles-lock.sh
. "$ROOT/scripts/lib/pi-profiles-lock.sh"
dotfiles_load_config

# Resolve the profile root once, to an absolute path (relative to the cwd;
# canonical when it exists) with CDPATH disabled, so a relative PI_HOME can't
# land in a CDPATH entry of the same name. Registration and every profile write
# below use this one path.
# No newline anywhere in it: the profile-roots registry is line-based, and
# command substitution drops trailing newlines (the trailing "x" keeps them, so
# they are refused rather than silently resolving to a different directory).
NL='
'
PI_ROOT="${PI_HOME:-$HOME/.pi}"
case "$PI_ROOT" in /*) ;; *) PI_ROOT="$PWD/$PI_ROOT" ;; esac
case "$PI_ROOT" in *"$NL"*) echo "setup-pi-profiles: PI_HOME contains a newline; refusing (the profile-roots registry is line-based)" >&2; exit 1 ;; esac
if [ -d "$PI_ROOT" ]; then
  PI_ROOT="$(CDPATH='' cd -P -- "$PI_ROOT" && pwd -P && printf x)" || { echo "setup-pi-profiles: cannot resolve $PI_ROOT" >&2; exit 1; }
  PI_ROOT="${PI_ROOT%x}"
  PI_ROOT="${PI_ROOT%"$NL"}"
  case "$PI_ROOT" in *"$NL"*) echo "setup-pi-profiles: PI_HOME resolves to a path containing a newline; refusing (the profile-roots registry is line-based)" >&2; exit 1 ;; esac
fi
PERSONAL_DIR="$PI_ROOT/agent"
WORK_SLUG="$DOTFILES_PI_WORK_PROFILE_SLUG"
WORK_FIRST="${WORK_SLUG%"${WORK_SLUG#?}"}"
WORK_LABEL="$(printf '%s' "$WORK_FIRST" | tr '[:lower:]' '[:upper:]')${WORK_SLUG#?}"
WORK_DIR="$PI_ROOT/agent-$WORK_SLUG"
HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
HERMES_SKILL="$HERMES_HOME_DIR/skills/software-development/coding-agent-account-routing/SKILL.md"
HERMES_ENABLED="$DOTFILES_ENABLE_HERMES"
MODE="dry-run"

usage() {
  cat <<EOF
setup-pi-profiles.sh — separate personal and work Pi profiles

Usage: scripts/setup-pi-profiles.sh [--dry-run | --apply | --check]

  (no flags)  Show the profile plan; write nothing.
  --dry-run   Same as no flags.
  --apply     Prepare the work profile and install the account-routing skill.
  --check     Verify the credential-free profile structure.
  -h, --help  Show this help.

Personal: $PERSONAL_DIR
Work:     $WORK_DIR

Set DOTFILES_PI_WORK_PROFILE_SLUG in the gitignored local.env to choose a local
profile name. The default slug is "work".
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE="dry-run" ;;
    --apply) MODE="apply" ;;
    --check) MODE="check" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "setup-pi-profiles: unknown flag: $arg" >&2; usage; exit 1 ;;
  esac
done

cat <<EOF
== Pi account profiles ==
mode:     $(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')
personal: $PERSONAL_DIR
work:     $WORK_DIR
Hermes:   $([ "$HERMES_ENABLED" = 1 ] && printf '%s' "$HERMES_SKILL" || printf 'disabled for this host')

The profiles share credential-free resources but keep auth, sessions, MCP state,
caches, settings, and trust decisions separate.
EOF

if [ "$MODE" = "dry-run" ]; then
  cat <<EOF

Would prepare the work profile. The credential-free Hermes account-routing
skill is installed only when DOTFILES_ENABLE_HERMES=1. No credentials are
copied or written.
EOF
  exit 0
fi

# The scaffold is not tracked in this public repo; resolve it the same way as
# setup-pi-agent.sh (DOTFILES_PI_SCAFFOLD_DIR, fork-local templates/pi fallback).
SCAFFOLD="${DOTFILES_PI_SCAFFOLD_DIR:-$ROOT/templates/pi}"
ACCOUNT_EXTENSION_SOURCE="$SCAFFOLD/agent/extensions/account-profile-indicator.ts"
PI_ACCOUNT_SKILL_SOURCE="$SCAFFOLD/agent/skills/coding-agent-account-routing/SKILL.md"
WORK_MODELS_SOURCE="$SCAFFOLD/agent/models.work.example.json"
GENERIC_CLOAK_SOURCE="$SCAFFOLD/agent/cloak.json"
HERMES_SKILL_SOURCE="$ROOT/templates/hermes/skills/software-development/coding-agent-account-routing/SKILL.md"

fail() {
  echo "setup-pi-profiles: $*" >&2
  return 1
}

models_match() {
  python3 - "$1" "$2" "$WORK_LABEL" <<'PY'
import json
import sys
from pathlib import Path

try:
    template = json.loads(Path(sys.argv[1]).read_text())
    actual = json.loads(Path(sys.argv[2]).read_text())
    label = sys.argv[3]
    for item in template["providers"]["anthropic"]["modelOverrides"].values():
        detail = item["name"].split(" · ", 1)[-1]
        item["name"] = f"{label} · {detail}"
except (OSError, KeyError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)
raise SystemExit(0 if template == actual else 1)
PY
}

write_models() {
  python3 - "$1" "$2" "$WORK_LABEL" <<'PY'
import json
import sys
from pathlib import Path

source, target, label = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
data = json.loads(source.read_text())
for item in data["providers"]["anthropic"]["modelOverrides"].values():
    detail = item["name"].split(" · ", 1)[-1]
    item["name"] = f"{label} · {detail}"
target.write_text(json.dumps(data, indent=2) + "\n")
PY
}

install_file_if_safe() {
  local source="$1" target="$2" label="$3"
  mkdir -p "$(dirname "$target")"
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    cp -p "$source" "$target"
    echo "  copy   $label"
    return
  fi
  if [ -L "$target" ]; then
    fail "$target is an unexpected symlink; reconcile it manually"
    return 1
  fi
  if cmp -s "$source" "$target"; then
    echo "  ok     $label"
    return
  fi
  fail "$target differs from the reviewed template; reconcile it manually"
}

share_path_if_present() {
  local source="$1" target="$2" label="$3"
  [ -e "$source" ] || return 0
  if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$source")" ]; then
    echo "  ok     shared $label"
    return
  fi
  if [ -e "$target" ] || [ -L "$target" ]; then
    fail "$target exists and is not the expected shared link"
    return 1
  fi
  ln -s "$source" "$target"
  echo "  link   $label"
}

# rexume (docs/rexume.md) and a work profile never coexist: rexume's Pi
# extension would load in the work profile through the shared extensions, and
# rexume reopens Pi without PI_CODING_AGENT_DIR, so a work conversation would
# come back under the personal profile. --apply refuses while rexume is
# installed, under the profiles lock `./dot rexume --apply` also takes
# (scripts/lib/pi-profiles-lock.sh); --check flags the combination.
check_profiles() {
  local failed=0 path sensitive_failed=0

  [ -d "$PERSONAL_DIR" ] || { echo "  MISS personal profile: $PERSONAL_DIR"; failed=1; }
  [ -d "$WORK_DIR" ] || { echo "  MISS work profile: $WORK_DIR"; failed=1; }
  cmp -s "$ACCOUNT_EXTENSION_SOURCE" "$PERSONAL_DIR/extensions/account-profile-indicator.ts" \
    && echo "  ok     account badge extension" \
    || { echo "  MISS or stale account badge extension"; failed=1; }
  cmp -s "$PI_ACCOUNT_SKILL_SOURCE" "$PERSONAL_DIR/skills/coding-agent-account-routing/SKILL.md" \
    && echo "  ok     Pi account-routing skill" \
    || { echo "  MISS or stale Pi account-routing skill"; failed=1; }

  for path in extensions skills themes npm; do
    [ -e "$PERSONAL_DIR/$path" ] || continue
    if [ -L "$WORK_DIR/$path" ] \
      && [ "$(readlink -f "$WORK_DIR/$path")" = "$(readlink -f "$PERSONAL_DIR/$path")" ]; then
      echo "  ok     shared $path"
    else
      echo "  MISS expected shared link: $WORK_DIR/$path"
      failed=1
    fi
  done

  local rexume_trace work_profiles
  work_profiles="$(dotfiles_pi_work_profiles "$PI_ROOT" | tr '\n' ' ')"
  if rexume_trace="$(dotfiles_rexume_trace "$PERSONAL_DIR")" && [ -n "$work_profiles" ]; then
    echo "  FAIL rexume is installed ($rexume_trace) alongside a work Pi profile (${work_profiles% }); they must not coexist (see docs/rexume.md)"
    failed=1
  fi

  if [ -L "$WORK_DIR/pi-codex-subagents" ]; then
    echo "  FAIL subagent runtime root must remain profile-local"
    failed=1
  fi
  for path in agents SYSTEM.md config.json; do
    [ -e "$PERSONAL_DIR/pi-codex-subagents/$path" ] || continue
    if [ -L "$WORK_DIR/pi-codex-subagents/$path" ] \
      && [ "$(readlink -f "$WORK_DIR/pi-codex-subagents/$path")" = "$(readlink -f "$PERSONAL_DIR/pi-codex-subagents/$path")" ]; then
      echo "  ok     shared pi-codex-subagents/$path"
    else
      echo "  MISS expected shared link: $WORK_DIR/pi-codex-subagents/$path"
      failed=1
    fi
  done

  if models_match "$WORK_MODELS_SOURCE" "$WORK_DIR/models.json" \
    && python3 - "$WORK_DIR" 2>/dev/null <<'PY'
import json
import sys
from pathlib import Path

profile = Path(sys.argv[1])
models = json.loads((profile / "models.json").read_text())
assert "apiKey" not in json.dumps(models)
memory = json.loads((profile / "memory-compiler.json").read_text())
assert memory.get("enabled") is False
PY
  then
    echo "  ok     work model labels and memory boundary"
  else
    echo "  FAIL work models.json or memory-compiler.json"
    failed=1
  fi

  for path in .cache auth.json anthropic-oat-setup-token-state.json \
    anthropic-oauth-state.json mcp-cache.json mcp-oauth mcp-onboarding.json \
    mcp.json pi-codex-subagents/runs sessions settings.json trust.json; do
    if [ -L "$WORK_DIR/$path" ] \
      || { [ -e "$PERSONAL_DIR/$path" ] && [ -e "$WORK_DIR/$path" ] \
        && [ "$PERSONAL_DIR/$path" -ef "$WORK_DIR/$path" ]; }; then
      echo "  FAIL sensitive/runtime path is shared: $path"
      failed=1
      sensitive_failed=1
    fi
  done
  [ "$sensitive_failed" -eq 0 ] \
    && echo "  ok     sensitive/runtime paths are not shared"

  if [ "$HERMES_ENABLED" = 1 ]; then
    cmp -s "$HERMES_SKILL_SOURCE" "$HERMES_SKILL" \
      && echo "  ok     Hermes account-routing skill" \
      || { echo "  MISS or stale Hermes account-routing skill: $HERMES_SKILL"; failed=1; }
  else
    echo "  skip   Hermes account-routing skill (disabled for this host)"
  fi

  return "$failed"
}

case "$MODE" in
  check)
    echo
    check_profiles
    ;;
  apply)
    # Decide and write under the profiles lock, so ./dot rexume --apply can't
    # interleave; then refuse any work profile while rexume is installed.
    # Always ~/.pi/.dotfiles-profiles.lock, whatever PI_HOME says.
    dotfiles_profiles_lock setup-pi-profiles || exit 1
    trap dotfiles_profiles_unlock EXIT
    if rexume_trace="$(dotfiles_rexume_trace "$PERSONAL_DIR")"; then
      fail "refusing to create or update a work Pi profile while rexume is installed ($rexume_trace): rexume's Pi extension would load in it through the shared extensions, and rexume reopens Pi without PI_CODING_AGENT_DIR. See docs/rexume.md (work profile)."
    fi
    [ -d "$PERSONAL_DIR" ] || fail "personal Pi profile not found: $PERSONAL_DIR"
    # Record this profile root (canonical) under the lock, before creating the
    # work profile, so `./dot rexume` also checks roots set up with a one-off
    # PI_HOME (docs/rexume.md). One line per root; never rewritten.
    PROFILE_ROOTS="$HOME/.pi/.dotfiles-profile-roots"
    profile_root="$PI_ROOT"   # absolute and canonical: PERSONAL_DIR exists under it
    # Only a regular file is read or appended: never through a symlink, and
    # never a FIFO (which would block) or a directory.
    if [ -L "$PROFILE_ROOTS" ] || { [ -e "$PROFILE_ROOTS" ] && [ ! -f "$PROFILE_ROOTS" ]; }; then
      fail "$PROFILE_ROOTS is not a regular file (a symlink, FIFO or directory); remove it by hand, then rerun"
    fi
    if [ -e "$PROFILE_ROOTS" ] && grep -Fxq -- "$profile_root" "$PROFILE_ROOTS"; then
      echo "  ok     profile root recorded"
    else
      printf '%s\n' "$profile_root" >> "$PROFILE_ROOTS" || fail "cannot record $profile_root in $PROFILE_ROOTS"
      echo "  record profile root $profile_root"
    fi
    for source in "$ACCOUNT_EXTENSION_SOURCE" "$PI_ACCOUNT_SKILL_SOURCE" "$WORK_MODELS_SOURCE" "$GENERIC_CLOAK_SOURCE"; do
      [ -f "$source" ] || fail "required template missing: $source"
    done
    if [ "$HERMES_ENABLED" = 1 ]; then
      [ -f "$HERMES_SKILL_SOURCE" ] || fail "required template missing: $HERMES_SKILL_SOURCE"
    fi

    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR"
    install_file_if_safe "$ACCOUNT_EXTENSION_SOURCE" \
      "$PERSONAL_DIR/extensions/account-profile-indicator.ts" "account badge extension"
    install_file_if_safe "$PI_ACCOUNT_SKILL_SOURCE" \
      "$PERSONAL_DIR/skills/coding-agent-account-routing/SKILL.md" "Pi account-routing skill"

    for path in extensions skills themes npm; do
      share_path_if_present "$PERSONAL_DIR/$path" "$WORK_DIR/$path" "$path"
    done
    mkdir -p "$WORK_DIR/pi-codex-subagents"
    chmod 700 "$WORK_DIR/pi-codex-subagents"
    for path in agents SYSTEM.md config.json; do
      share_path_if_present "$PERSONAL_DIR/pi-codex-subagents/$path" \
        "$WORK_DIR/pi-codex-subagents/$path" "pi-codex-subagents/$path"
    done

    if [ ! -e "$WORK_DIR/settings.json" ] && [ ! -L "$WORK_DIR/settings.json" ]; then
      printf '%s\n' '{' \
        '  "defaultProvider": "anthropic",' \
        '  "defaultModel": "claude-sonnet-4-6"' \
        '}' > "$WORK_DIR/settings.json"
      echo "  write  independent work settings"
    elif [ -L "$WORK_DIR/settings.json" ]; then
      fail "$WORK_DIR/settings.json must not be a symlink"
    else
      echo "  keep   independent work settings"
    fi

    install_file_if_safe "$GENERIC_CLOAK_SOURCE" "$WORK_DIR/cloak.json" \
      "generic work Cloak rules"

    if [ ! -e "$WORK_DIR/memory-compiler.json" ]; then
      printf '%s\n' '{' '  "enabled": false' '}' > "$WORK_DIR/memory-compiler.json"
      echo "  write  disabled work memory compiler"
    fi

    if [ ! -e "$WORK_DIR/models.json" ]; then
      write_models "$WORK_MODELS_SOURCE" "$WORK_DIR/models.json"
      echo "  write  work model labels"
    elif models_match "$WORK_MODELS_SOURCE" "$WORK_DIR/models.json"; then
      echo "  ok     work model labels"
    else
      fail "$WORK_DIR/models.json differs from the rendered template; reconcile it manually"
    fi

    if [ "$HERMES_ENABLED" = 1 ]; then
      install_file_if_safe "$HERMES_SKILL_SOURCE" "$HERMES_SKILL" \
        "Hermes account-routing skill"
    else
      echo "  skip   Hermes account-routing skill (disabled for this host)"
    fi

    echo
    check_profiles
    echo "Restart Pi processes to load new model labels; skills/extensions can use /reload."
    ;;
esac
