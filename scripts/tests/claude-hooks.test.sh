#!/usr/bin/env bash
# Focused tests for scripts/setup-claude-memory-hooks.sh: merge preserves
# unrelated hooks/settings, apply is idempotent, and --check reports state.
# No system state is touched — everything runs against a temp HOME.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../setup-claude-memory-hooks.sh"

pass=0; fail=0
ok()   { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL %s (got: %s)\n' "$1" "${2:-}"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export DOTFILES_LOCAL_ENV="$TMP/no-local.env"
export PI_MEMORY_COMPILER_DIR="$TMP/compiler"
export CLAUDE_SETTINGS="$TMP/.claude/settings.json"
mkdir -p "$TMP/compiler/hooks" "$TMP/.claude"
touch "$TMP/compiler/hooks/session-start.py" \
      "$TMP/compiler/hooks/pre-compact.py" \
      "$TMP/compiler/hooks/session-end.py"

# Pre-existing settings with an unrelated hook and unrelated keys.
cat > "$CLAUDE_SETTINGS" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "SessionStart": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "echo unrelated", "timeout": 5}]}
    ]
  }
}
EOF

# --- 1: dry-run writes nothing --------------------------------------------
before="$(cat "$CLAUDE_SETTINGS")"
bash "$SCRIPT" --dry-run > /dev/null 2>&1
check "dry-run leaves settings untouched" "$(cat "$CLAUDE_SETTINGS")" "$before"

# --- 2: apply wires all three events --------------------------------------
bash "$SCRIPT" --apply > /dev/null 2>&1
events="$(jq -r '.hooks | keys | sort | join(",")' "$CLAUDE_SETTINGS")"
check "all three events present" "$events" "PreCompact,SessionEnd,SessionStart"

# --- 3: unrelated hook and settings preserved ------------------------------
check "unrelated SessionStart hook preserved" \
  "$(jq -r '[.hooks.SessionStart[].hooks[].command] | any(. == "echo unrelated")' "$CLAUDE_SETTINGS")" "true"
check "unrelated top-level key preserved" "$(jq -r '.model' "$CLAUDE_SETTINGS")" "opus"

# --- 4: hook commands point at the compiler checkout -----------------------
check "SessionEnd hook targets compiler" \
  "$(jq -r --arg d "$TMP/compiler" '[.hooks.SessionEnd[].hooks[].command | contains($d)] | any' "$CLAUDE_SETTINGS")" "true"

# --- 5: apply is idempotent ------------------------------------------------
after_first="$(cat "$CLAUDE_SETTINGS")"
bash "$SCRIPT" --apply > /dev/null 2>&1
check "second apply changes nothing" "$(cat "$CLAUDE_SETTINGS")" "$after_first"

# --- 6: check passes when wired, fails when not ----------------------------
bash "$SCRIPT" --check > /dev/null 2>&1 && ok "check passes when wired" || bad "check passes when wired" "rc=$?"
CLAUDE_SETTINGS="$TMP/absent.json" bash "$SCRIPT" --check > /dev/null 2>&1 \
  && bad "check fails when unwired" "rc=0" || ok "check fails when unwired"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
