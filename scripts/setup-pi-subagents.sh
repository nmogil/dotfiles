#!/usr/bin/env bash
# setup-pi-subagents.sh — install the reviewed Pi subagent stack from a pinned
# threeonefour source commit. Safe by default: no flags means dry-run.
set -euo pipefail

REPO_URL="https://github.com/WeShipWork/threeonefour.git"
REF="7f86a2931f83b68f7915fd132a026bb8fa76ae97"
PNPM_VERSION="11.6.0"
SHORT_REF="${REF:0:12}"
PACKAGE_ROOT="${PI_PACKAGE_HOME:-$HOME/.local/share/pi-packages}"
CHECKOUT="${PI_SUBAGENTS_CHECKOUT:-$PACKAGE_ROOT/threeonefour-$SHORT_REF}"
PI_ROOT="${PI_HOME:-$HOME/.pi}"
AGENT_DIR="${PI_CODING_AGENT_DIR:-$PI_ROOT/agent}"
PI_BIN="${PI_BIN:-pi}"
MODE="dry-run"

usage() {
  cat <<EOF
setup-pi-subagents.sh — pinned Pi-first subagent setup

Usage: scripts/setup-pi-subagents.sh [--dry-run | --apply | --check]

  (no flags)   Show the pinned checkout and install operations; write nothing.
  --dry-run    Same as no flags.
  --apply      Fetch the pinned source, install locked dependencies, and add
               pi-subagents plus pi-herdr to the user's Pi settings.
  --check      Read-only verification of the checkout and Pi package entries.
  -h, --help   Show this help.

Source:   $REPO_URL
Commit:   $REF
Checkout: $CHECKOUT
Agent dir: $AGENT_DIR

This intentionally does not install pi-herd transcript mirrors.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE="dry-run" ;;
    --apply) MODE="apply" ;;
    --check) MODE="check" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "setup-pi-subagents: unknown flag: $arg" >&2; usage; exit 1 ;;
  esac
done

print_plan() {
  local mode_label
  mode_label="$(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')"
  cat <<EOF
== Pi subagent stack ==
mode:     $mode_label
source:   $REPO_URL
commit:   $REF
checkout: $CHECKOUT
agent dir: $AGENT_DIR
packages:
  $CHECKOUT/packages/pi-subagents
  $CHECKOUT/packages/pi-herdr
excluded:
  pi-herd (mirror UI is still incomplete upstream)
EOF
}

check_routing_assets() {
  local failed=0 relative
  for relative in \
    subagents.json \
    agent-tool-description.md \
    agents/engineer.md \
    agents/reviewer.md \
    agents/sol-reviewer.md \
    agents/writer.md \
    agents/adjudicator.md \
    skills/subagent-routing/SKILL.md; do
    if [ -f "$AGENT_DIR/$relative" ]; then
      echo "  ok   routing asset: $relative"
    else
      echo "  MISS routing asset: $AGENT_DIR/$relative"
      failed=1
    fi
  done
  return "$failed"
}

check_installation() {
  local failed=0 settings_path
  settings_path="$AGENT_DIR/settings.json"
  if [ -d "$CHECKOUT/.git" ]; then
    local head dirty
    head="$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null || true)"
    dirty="$(git -C "$CHECKOUT" status --porcelain 2>/dev/null || true)"
    if [ "$head" = "$REF" ] && [ -z "$dirty" ]; then
      echo "  ok   pinned checkout: $SHORT_REF"
    else
      echo "  FAIL checkout must be clean at $REF (found ${head:-unknown})"
      failed=1
    fi
  else
    echo "  MISS pinned checkout: $CHECKOUT"
    failed=1
  fi

  if ! command -v "$PI_BIN" >/dev/null 2>&1; then
    echo "  MISS Pi CLI not found: $PI_BIN"
    failed=1
  elif [ ! -f "$settings_path" ]; then
    echo "  MISS Pi settings not found: $settings_path"
    failed=1
  else
    for package in pi-subagents pi-herdr; do
      if node -e '
        const fs = require("node:fs");
        const path = require("node:path");
        const [settingsPath, expectedPath] = process.argv.slice(1);
        const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
        const base = path.dirname(settingsPath);
        const found = (settings.packages ?? []).some((entry) => {
          const source = typeof entry === "string" ? entry : entry?.source;
          return typeof source === "string" && path.resolve(base, source) === path.resolve(expectedPath);
        });
        process.exit(found ? 0 : 1);
      ' "$settings_path" "$CHECKOUT/packages/$package"; then
        echo "  ok   Pi package installed: $package"
      else
        echo "  MISS Pi package not installed: $package"
        failed=1
      fi
    done
  fi
  if ! check_routing_assets; then failed=1; fi
  return "$failed"
}

print_plan

case "$MODE" in
  dry-run)
    cat <<EOF

Would:
  1. create an immutable checkout at the pinned commit;
  2. install production dependencies from the repository's frozen lockfile;
  3. run pi install for pi-subagents and pi-herdr.

No files or Pi settings were changed. Re-run with --apply to install.
EOF
    ;;
  check)
    echo
    check_installation
    ;;
  apply)
    if ! check_routing_assets; then
      echo "setup-pi-subagents: apply the Pi scaffold before installing packages" >&2
      echo "  ./dot pi scaffold --apply" >&2
      exit 1
    fi
    for command in git node corepack "$PI_BIN"; do
      command -v "$command" >/dev/null 2>&1 || {
        echo "setup-pi-subagents: required command not found: $command" >&2
        exit 1
      }
    done
    node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && minor < 19)) process.exit(1)' || {
      echo "setup-pi-subagents: Node.js >=22.19.0 is required" >&2
      exit 1
    }

    if [ -e "$CHECKOUT" ]; then
      [ -d "$CHECKOUT/.git" ] || {
        echo "setup-pi-subagents: refusing non-git checkout path: $CHECKOUT" >&2
        exit 1
      }
      head="$(git -C "$CHECKOUT" rev-parse HEAD)"
      dirty="$(git -C "$CHECKOUT" status --porcelain)"
      [ "$head" = "$REF" ] && [ -z "$dirty" ] || {
        echo "setup-pi-subagents: existing checkout is not clean at $REF" >&2
        exit 1
      }
      echo "  reuse pinned checkout"
    else
      mkdir -p "$PACKAGE_ROOT"
      tmp="$(mktemp -d "${CHECKOUT}.tmp.XXXXXX")"
      trap 'rm -rf "$tmp"' EXIT
      git -C "$tmp" init -q
      git -C "$tmp" remote add origin "$REPO_URL"
      git -C "$tmp" fetch -q --depth 1 origin "$REF"
      git -C "$tmp" checkout -q --detach FETCH_HEAD
      [ "$(git -C "$tmp" rev-parse HEAD)" = "$REF" ] || {
        echo "setup-pi-subagents: fetched commit did not match pin" >&2
        exit 1
      }
      mv "$tmp" "$CHECKOUT"
      trap - EXIT
      echo "  fetched pinned checkout"
    fi

    # Runtime imports are declared in dependencies. Omitting workspace dev peers
    # prevents the checkout from shadowing the active Pi runtime package.
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack "pnpm@$PNPM_VERSION" --dir "$CHECKOUT" install --frozen-lockfile --prod
    PI_CODING_AGENT_DIR="$AGENT_DIR" "$PI_BIN" install "$CHECKOUT/packages/pi-subagents"
    PI_CODING_AGENT_DIR="$AGENT_DIR" "$PI_BIN" install "$CHECKOUT/packages/pi-herdr"
    echo
    if ! check_installation; then
      echo "setup-pi-subagents: packages were installed but verification failed" >&2
      exit 1
    fi
    echo "Restart Pi or run /reload before using the new tools."
    ;;
esac
