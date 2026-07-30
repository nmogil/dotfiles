#!/usr/bin/env bash
# setup-claude-memory-hooks.sh — wire claude-memory-compiler capture hooks into
# ~/.claude/settings.json (SessionStart / PreCompact / SessionEnd) so Claude
# Code conversations flush into the knowledge base. Opt-in; not run by setup.sh.
# See docs/claude-memory-compiler.md.
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

COMPILER_DIR="${PI_MEMORY_COMPILER_DIR:-$HOME/github_repos/personal/claude-memory-compiler}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
MARKER="claude-memory-compiler"
MODE="dry-run"
# Bake the absolute uv path into the hook commands: Claude Code runs hooks via
# /bin/sh with the launch environment, not an interactive shell, so a bare `uv`
# breaks whenever uv lives on a shell-rc-only PATH (e.g. a pip --user install).
UV_BIN="$(command -v uv 2>/dev/null || echo uv)"

usage() {
  cat <<EOF
setup-claude-memory-hooks.sh — Claude Code capture hooks for the memory compiler

Usage: scripts/setup-claude-memory-hooks.sh [--dry-run | --apply | --check]

  (no flags)  Show the settings.json that --apply would write; write nothing.
  --dry-run   Same as no flags.
  --apply     Merge the hooks into $SETTINGS (backs up the existing file).
  --check     Verify the hooks are installed and the compiler checkout exists.

Compiler checkout: $COMPILER_DIR
(override with PI_MEMORY_COMPILER_DIR in ~/.config/dotfiles/local.env)
EOF
}

case "${1:-}" in
  ''|--dry-run) MODE="dry-run" ;;
  --apply)      MODE="apply" ;;
  --check)      MODE="check" ;;
  -h|--help)    usage; exit 0 ;;
  *) echo "setup-claude-memory-hooks: unknown flag: $1" >&2; usage; exit 1 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "setup-claude-memory-hooks: jq is required" >&2; exit 1; }

# Existing settings (or empty object), merged with the three capture hooks.
# Any prior hook entry mentioning the compiler is replaced, so re-running is
# idempotent and updates paths; unrelated hooks and settings are preserved.
merged_settings() {
  local existing="{}"
  [ -f "$SETTINGS" ] && existing="$(cat "$SETTINGS")"
  jq --arg dir "$COMPILER_DIR" --arg marker "$MARKER" --arg uv "$UV_BIN" '
    def hook($script; $t):
      [{matcher: "", hooks: [{type: "command",
        command: ($uv + " --project \"" + $dir + "\" run python \"" + $dir + "/hooks/" + $script + "\""),
        timeout: $t}]}];
    def is_ours:
      contains($marker) or contains($dir)
      or test("run python .*hooks/(session-start|pre-compact|session-end)\\.py");
    def keep_others:
      map(select([.hooks[]?.command // empty | is_ours] | any | not));
    .hooks = (.hooks // {})
    | .hooks.SessionStart = (((.hooks.SessionStart // []) | keep_others) + hook("session-start.py"; 15))
    | .hooks.PreCompact   = (((.hooks.PreCompact   // []) | keep_others) + hook("pre-compact.py"; 10))
    | .hooks.SessionEnd   = (((.hooks.SessionEnd   // []) | keep_others) + hook("session-end.py"; 10))
  ' <<<"$existing"
}

check() {
  local rc=0 script
  for script in session-start.py pre-compact.py session-end.py; do
    if [ -f "$COMPILER_DIR/hooks/$script" ]; then
      echo "  ok   compiler hook present: $script"
    else
      echo "  FAIL missing $COMPILER_DIR/hooks/$script (clone nmogil/claude-memory-compiler)"
      rc=1
    fi
  done
  if command -v uv >/dev/null 2>&1; then
    echo "  ok   uv installed"
  else
    echo "  FAIL uv not installed (hooks run via uv)"
    rc=1
  fi
  local event
  for event in SessionStart PreCompact SessionEnd; do
    if [ -f "$SETTINGS" ] && jq -e --arg e "$event" --arg dir "$COMPILER_DIR" \
      '.hooks[$e] // [] | [.[].hooks[]?.command // empty | contains($dir)] | any' \
      "$SETTINGS" >/dev/null 2>&1; then
      echo "  ok   $event hook wired in $SETTINGS"
    else
      echo "  FAIL $event hook missing from $SETTINGS (run --apply)"
      rc=1
    fi
  done
  return "$rc"
}

case "$MODE" in
  dry-run)
    echo "Would write to $SETTINGS (compiler: $COMPILER_DIR):"
    merged_settings
    ;;
  apply)
    new="$(merged_settings)"
    mkdir -p "$(dirname "$SETTINGS")"
    if [ -f "$SETTINGS" ]; then
      if [ "$(jq -S . "$SETTINGS")" = "$(jq -S . <<<"$new")" ]; then
        echo "Already wired; $SETTINGS unchanged."
        exit 0
      fi
      cp "$SETTINGS" "$SETTINGS.bak"
      echo "Backed up existing settings to $SETTINGS.bak"
    fi
    printf '%s\n' "$new" > "$SETTINGS.tmp"
    jq -e . "$SETTINGS.tmp" >/dev/null   # never install unparseable settings
    mv "$SETTINGS.tmp" "$SETTINGS"
    echo "Wired memory-compiler hooks into $SETTINGS"
    ;;
  check)
    check
    ;;
esac
