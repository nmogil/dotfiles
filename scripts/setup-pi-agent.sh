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
  --install    Print/run the pinned npm Pi CLI install and migrate an existing
               Vite+ Pi global package after confirmation. Not run during --apply.
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

resolve_path() {
  local src="$1" dir target
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    target="$(readlink "$src")"
    if [[ "$target" = /* ]]; then src="$target"; else src="$dir/$target"; fi
  done
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  printf '%s/%s\n' "$dir" "$(basename "$src")"
}

find_standalone_npm() {
  local dir node_bin npm_cli version
  if [ -n "${PI_NPM_NODE:-}" ] || [ -n "${PI_NPM_CLI:-}" ]; then
    [ -x "${PI_NPM_NODE:-}" ] && [ -f "${PI_NPM_CLI:-}" ] || return 1
    NPM_NODE="$PI_NPM_NODE"
    NPM_CLI="$PI_NPM_CLI"
    return 0
  fi
  for dir in /opt/homebrew/bin /usr/local/bin /usr/bin; do
    node_bin="$dir/node"
    npm_cli="$dir/npm"
    [ -x "$node_bin" ] && [ -e "$npm_cli" ] || continue
    case "$(resolve_path "$node_bin"):$(resolve_path "$npm_cli")" in
      *"/.vite-plus/"*) continue ;;
    esac
    version="$($node_bin -p 'process.versions.node' 2>/dev/null || true)"
    "$node_bin" -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && minor < 19)) process.exit(1)' 2>/dev/null || continue
    NPM_NODE="$node_bin"
    NPM_CLI="$npm_cli"
    echo "Using standalone Node/npm: $node_bin ($version), $npm_cli"
    return 0
  done
  return 1
}

install_cli() {
  local package="@earendil-works/pi-coding-agent@0.80.6"
  local package_name="@earendil-works/pi-coding-agent"
  local current="" resolved="" npm_prefix="" npm_pi=""
  local NPM_NODE="" NPM_CLI=""

  cat <<EOF
== Install the Pi CLI (npm) ==
Pinned command:

  npm install -g $package

The npm distribution is required for runtime-importing Pi extensions such as
pi-subagents. The Vite+ global layout currently breaks those imports. This flow
uses Node.js >=22.19 and npm outside Vite+'s managed runtime. After a successful
npm install, it removes only Vite+'s global Pi package; Vite+ itself and its
project tooling remain installed.

EOF

  current="$(command -v pi 2>/dev/null || true)"
  if [ -n "$current" ]; then
    resolved="$(resolve_path "$current")"
    case "$current:$resolved" in
      *"/.vite-plus/"*) echo "Current Pi uses Vite+: $current (migration needed)" ;;
      *)
        if [ "$(pi --version 2>/dev/null || true)" = "0.80.6" ]; then
          echo "Pi npm installation already active: $current (0.80.6)"
          return 0
        fi
        echo "Current non-Vite+ Pi will be replaced: $current"
        ;;
    esac
  fi

  printf "Install pinned npm Pi and remove the Vite+ Pi package? [y/N] "
  read -r ans
  case "$ans" in
    y|Y)
      find_standalone_npm || {
        echo "setup-pi-agent: Node.js >=22.19 with npm outside Vite+ is required" >&2
        exit 1
      }
      npm_prefix="$("$NPM_NODE" "$NPM_CLI" prefix -g)"
      if [ -e "$npm_prefix" ] && [ ! -w "$npm_prefix" ]; then
        npm_prefix="$HOME/.local"
        echo "Global npm prefix is not writable; using user prefix: $npm_prefix"
      fi
      mkdir -p "$npm_prefix"
      "$NPM_NODE" "$NPM_CLI" install -g --prefix "$npm_prefix" "$package"
      npm_pi="$npm_prefix/bin/pi"
      [ -x "$npm_pi" ] || {
        echo "setup-pi-agent: npm installed Pi but no executable was found at $npm_pi" >&2
        exit 1
      }
      [ "$($npm_pi --version)" = "0.80.6" ] || {
        echo "setup-pi-agent: npm Pi version verification failed" >&2
        exit 1
      }

      if [ -e "$HOME/.vite-plus/bin/pi" ] || [ -L "$HOME/.vite-plus/bin/pi" ]; then
        command -v vp >/dev/null 2>&1 || {
          echo "setup-pi-agent: Vite+ Pi still shadows npm Pi, but vp is unavailable" >&2
          exit 1
        }
        vp remove -g "$package_name"
      fi

      PATH="$(dirname "$npm_pi"):$PATH"
      export PATH
      hash -r
      current="$(command -v pi 2>/dev/null || true)"
      resolved="$(resolve_path "$current")"
      case "$current:$resolved" in
        *"/.vite-plus/"*)
          echo "setup-pi-agent: Vite+ Pi still shadows $npm_pi; fix PATH before continuing" >&2
          exit 1
          ;;
      esac
      [ "$(pi --version 2>/dev/null || true)" = "0.80.6" ] || {
        echo "setup-pi-agent: active Pi is not the pinned npm version" >&2
        exit 1
      }
      echo "Pi npm installation active: $(command -v pi) ($(pi --version))"
      ;;
    *) echo "Skipped. Run 'npm install -g $package' when ready." ;;
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
  cd "$ROOT"
  ./dot pi subagents --apply     # optional pinned Pi-first delegation stack
  pi /reload
EOF
else
  echo "Would copy $copied file(s). Re-run with --apply to write them."
  echo "Existing files are skipped unless you add --force (which backs them up)."
fi
