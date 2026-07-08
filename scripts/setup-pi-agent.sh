#!/usr/bin/env bash
# setup-pi-agent.sh — opt-in installer for the Pi coding agent scaffold.
#
# Safe by default: with no flags it does a DRY RUN and writes nothing. It copies
# the inert scaffold from templates/pi/ into ${PI_HOME:-$HOME/.pi} only with
# --apply, and never overwrites an existing file unless you pass --force (which
# backs the file up first). It can optionally install the pi CLI with --install.
#
# It deliberately does NOT: run npm install, create your real settings.json /
# mcp.json (copy the *.example.json yourself), or touch any auth/session state.
set -euo pipefail

script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir; dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"; [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

ROOT="$(cd "$(script_dir)/.." && pwd)"
SRC="$ROOT/templates/pi"
DEST="${PI_HOME:-$HOME/.pi}"

APPLY=0 FORCE=0 INSTALL=0
usage() {
  cat <<EOF
setup-pi-agent.sh — opt-in Pi agent scaffold installer

Usage: scripts/setup-pi-agent.sh [--apply] [--force] [--install] [--dry-run]

  (no flags)   Dry run: show what would be copied. Writes nothing.
  --dry-run    Same as no flags (explicit).
  --apply      Copy templates/pi/ into \${PI_HOME:-\$HOME/.pi}, skipping files
               that already exist.
  --force      With --apply: overwrite existing files, backing each up first
               to <file>.bak.<timestamp>.
  --install    Print/run the documented pi CLI install flow (Vite+), then exit.
               Not run during --apply.
  -h, --help   This help.

Source: $SRC
Dest:   $DEST
EOF
}

for arg in "$@"; do
  case "$arg" in
    --apply)   APPLY=1 ;;
    --force)   FORCE=1 ;;
    --install) INSTALL=1 ;;
    --dry-run) APPLY=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "setup-pi-agent: unknown flag: $arg" >&2; usage; exit 1 ;;
  esac
done

install_cli() {
  cat <<'EOF'
== Install the Pi CLI (Vite+) ==
This follows dmmulroy's documented flow. Review before running:

  curl -fsSL https://vite.plus | bash
  vp install -g @earendil-works/pi-coding-agent

EOF
  if command -v pi >/dev/null 2>&1; then
    echo "pi already present: $(command -v pi)"; return 0
  fi
  printf "Run the install commands now? [y/N] "
  read -r ans
  case "$ans" in
    y|Y)
      curl -fsSL https://vite.plus | bash
      if ! command -v vp >/dev/null 2>&1 && [ -f "$HOME/.vite-plus/env" ]; then
        # The Vite+ installer updates shell startup files, but this script keeps
        # running in the current non-login shell. Load the just-installed env so
        # the subsequent `vp install` works without asking for a new terminal.
        # shellcheck disable=SC1091
        . "$HOME/.vite-plus/env"
      fi
      vp install -g @earendil-works/pi-coding-agent
      ;;
    *) echo "Skipped. Run the two commands above yourself when ready." ;;
  esac
}

if [ "$INSTALL" = 1 ]; then
  install_cli
  exit 0
fi

[ -d "$SRC" ] || { echo "setup-pi-agent: scaffold not found: $SRC" >&2; exit 1; }

ts="$(date +%Y%m%d-%H%M%S)"
mode="DRY RUN (no changes)"; [ "$APPLY" = 1 ] && mode="APPLY"
force_note=""; [ "$FORCE" = 1 ] && force_note=" (force overwrite)"
echo "== Pi agent scaffold =="
echo "source: $SRC"
echo "dest:   $DEST"
echo "mode:   $mode$force_note"
echo

copied=0 skipped=0 backed=0
# Walk every scaffold file (including dotfiles like .gitignore) relative to SRC.
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  target="$DEST/$rel"
  if [ -e "$target" ] && [ "$FORCE" != 1 ]; then
    echo "  skip   $rel (exists)"; skipped=$((skipped+1)); continue
  fi
  if [ "$APPLY" = 1 ]; then
    mkdir -p "$(dirname "$target")"
    if [ -e "$target" ] && [ "$FORCE" = 1 ]; then
      cp -p "$target" "$target.bak.$ts"; echo "  backup $rel -> $rel.bak.$ts"; backed=$((backed+1))
    fi
    cp -p "$f" "$target"; echo "  copy   $rel"; copied=$((copied+1))
  else
    echo "  would  $rel"; copied=$((copied+1))
  fi
done < <(find "$SRC" -type f -print0)

echo
if [ "$APPLY" = 1 ]; then
  echo "Copied $copied, skipped $skipped, backed up $backed."
  cat <<EOF

Next steps (manual — this script does none of these):
  cd "$DEST"
  npm install
  cp agent/settings.example.json agent/settings.json   # then edit provider/model
  cp agent/mcp.example.json      agent/mcp.json         # then edit MCP servers
  pi /reload
EOF
else
  echo "Would copy $copied file(s). Re-run with --apply to write them."
  echo "Existing files are skipped unless you add --force (which backs them up)."
fi
