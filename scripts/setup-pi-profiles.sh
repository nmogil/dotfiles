#!/usr/bin/env bash
# setup-pi-profiles.sh — prepare separate personal and work Pi credential
# profiles without copying auth, sessions, MCP credentials, or caches.
set -euo pipefail

script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

ROOT="$(cd "$(script_dir)/.." && pwd)"
# shellcheck source=lib/local-env.sh
. "$ROOT/scripts/lib/local-env.sh"
dotfiles_load_config

PI_ROOT="${PI_HOME:-$HOME/.pi}"
PERSONAL_DIR="$PI_ROOT/agent"
WORK_SLUG="$DOTFILES_PI_WORK_PROFILE_SLUG"
WORK_FIRST="${WORK_SLUG%"${WORK_SLUG#?}"}"
WORK_LABEL="$(printf '%s' "$WORK_FIRST" | tr '[:lower:]' '[:upper:]')${WORK_SLUG#?}"
WORK_DIR="$PI_ROOT/agent-$WORK_SLUG"
HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
HERMES_SKILL="$HERMES_HOME_DIR/skills/software-development/coding-agent-account-routing/SKILL.md"
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
Hermes:   $HERMES_SKILL

The profiles share credential-free resources but keep auth, sessions, MCP state,
caches, settings, and trust decisions separate.
EOF

if [ "$MODE" = "dry-run" ]; then
  cat <<EOF

Would prepare the work profile and install the credential-free Hermes account
routing skill. No credentials are copied or written.
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

  for path in extensions skills themes npm agents; do
    [ -e "$PERSONAL_DIR/$path" ] || continue
    if [ -L "$WORK_DIR/$path" ] \
      && [ "$(readlink -f "$WORK_DIR/$path")" = "$(readlink -f "$PERSONAL_DIR/$path")" ]; then
      echo "  ok     shared $path"
    else
      echo "  MISS expected shared link: $WORK_DIR/$path"
      failed=1
    fi
  done

  for path in subagents.json agent-tool-description.md; do
    [ -e "$PERSONAL_DIR/$path" ] || continue
    if [ -L "$WORK_DIR/$path" ] \
      && [ "$(readlink -f "$WORK_DIR/$path")" = "$(readlink -f "$PERSONAL_DIR/$path")" ]; then
      echo "  ok     shared $path"
    else
      echo "  MISS expected shared link: $WORK_DIR/$path"
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
    mcp.json sessions settings.json trust.json; do
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

  cmp -s "$HERMES_SKILL_SOURCE" "$HERMES_SKILL" \
    && echo "  ok     Hermes account-routing skill" \
    || { echo "  MISS or stale Hermes account-routing skill: $HERMES_SKILL"; failed=1; }

  return "$failed"
}

case "$MODE" in
  check)
    echo
    check_profiles
    ;;
  apply)
    [ -d "$PERSONAL_DIR" ] || fail "personal Pi profile not found: $PERSONAL_DIR"
    for source in "$ACCOUNT_EXTENSION_SOURCE" "$PI_ACCOUNT_SKILL_SOURCE" "$WORK_MODELS_SOURCE" "$GENERIC_CLOAK_SOURCE" "$HERMES_SKILL_SOURCE"; do
      [ -f "$source" ] || fail "required template missing: $source"
    done

    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR"
    install_file_if_safe "$ACCOUNT_EXTENSION_SOURCE" \
      "$PERSONAL_DIR/extensions/account-profile-indicator.ts" "account badge extension"
    install_file_if_safe "$PI_ACCOUNT_SKILL_SOURCE" \
      "$PERSONAL_DIR/skills/coding-agent-account-routing/SKILL.md" "Pi account-routing skill"

    for path in extensions skills themes npm agents; do
      share_path_if_present "$PERSONAL_DIR/$path" "$WORK_DIR/$path" "$path"
    done
    for path in subagents.json agent-tool-description.md; do
      share_path_if_present "$PERSONAL_DIR/$path" "$WORK_DIR/$path" "$path"
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

    install_file_if_safe "$HERMES_SKILL_SOURCE" "$HERMES_SKILL" \
      "Hermes account-routing skill"

    echo
    check_profiles
    echo "Restart Pi processes to load new model labels; skills/extensions can use /reload."
    ;;
esac
