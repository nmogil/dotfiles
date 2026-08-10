#!/usr/bin/env bash
# setup-pi-subagents.sh — install the reviewed Pi Codex subagent extension from
# an exact npm version. Safe by default: no flags means dry-run.
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
load_local_env || true
PI_SCAFFOLD_DIR="${DOTFILES_PI_SCAFFOLD_DIR:-$ROOT/templates/pi}"
TEMPLATE_AGENT_DIR="$PI_SCAFFOLD_DIR/agent"
PACKAGE_NAME="@ogulcancelik/pi-codex-subagents"
PACKAGE_VERSION="0.3.2"
PACKAGE_SOURCE="npm:$PACKAGE_NAME@$PACKAGE_VERSION"
EXPECTED_PI_VERSION="0.84.1"
PI_ROOT="${PI_HOME:-$HOME/.pi}"
AGENT_DIR="${PI_CODING_AGENT_DIR:-$PI_ROOT/agent}"
PI_BIN="${PI_BIN:-pi}"
LEGACY_BACKUP_DIR="$AGENT_DIR/migrations/pi-subagents-legacy"
MIGRATION_PERFORMED=0
MODE="dry-run"
AGENT_BASENAME="$(basename "$AGENT_DIR")"
case "$AGENT_BASENAME" in
  agent) PROFILE_LABEL="personal" ;;
  agent-*) PROFILE_LABEL="${AGENT_BASENAME#agent-}" ;;
  *) PROFILE_LABEL="$AGENT_BASENAME" ;;
esac

usage() {
  cat <<EOF
setup-pi-subagents.sh — pinned Pi Codex subagent setup

Usage: scripts/setup-pi-subagents.sh [--dry-run | --apply | --check]

  (no flags)   Show the exact package install; write nothing.
  --dry-run    Same as no flags.
  --apply      Install $PACKAGE_SOURCE into the selected Pi profile and archive
               the replaced WeShipWork delegation assets.
  --check      Read-only verification of package settings, installed version,
               Pi runtime, migration state, and exact reviewed routing assets.
  -h, --help   Show this help.

Package:   $PACKAGE_SOURCE
Agent dir: $AGENT_DIR
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
== Pi Codex subagents ==
mode:      $mode_label
package:   $PACKAGE_SOURCE
agent dir: $AGENT_DIR
profile:   $PROFILE_LABEL
legacy:    $LEGACY_BACKUP_DIR
EOF
}

check_routing_assets() {
  local failed=0 relative
  for relative in \
    pi-codex-subagents/SYSTEM.md \
    pi-codex-subagents/config.json \
    pi-codex-subagents/agents/engineer.md \
    pi-codex-subagents/agents/architect.md \
    pi-codex-subagents/agents/analyst.md \
    pi-codex-subagents/agents/reviewer.md \
    pi-codex-subagents/agents/sol-reviewer.md \
    pi-codex-subagents/agents/writer.md \
    pi-codex-subagents/agents/adjudicator.md \
    skills/subagent-routing/SKILL.md \
    skills/coding-agent-account-routing/SKILL.md; do
    if [ -f "$AGENT_DIR/$relative" ] \
      && cmp -s "$TEMPLATE_AGENT_DIR/$relative" "$AGENT_DIR/$relative"; then
      echo "  ok   exact routing asset: $relative"
    else
      echo "  MISS or stale routing asset: $AGENT_DIR/$relative"
      failed=1
    fi
  done
  return "$failed"
}

legacy_assets_present() {
  local relative
  for relative in subagents.json agent-tool-description.md agents; do
    if [ -e "$AGENT_DIR/$relative" ] || [ -L "$AGENT_DIR/$relative" ]; then
      return 0
    fi
  done
  return 1
}

legacy_migration_needed() {
  legacy_assets_present \
    || { [ -f "$AGENT_DIR/settings.json" ] && legacy_settings_packages check; }
}

preflight_legacy_archive() {
  if legacy_migration_needed \
    && { [ -e "$LEGACY_BACKUP_DIR" ] || [ -L "$LEGACY_BACKUP_DIR" ]; }; then
    echo "setup-pi-subagents: legacy state remains but backup already exists: $LEGACY_BACKUP_DIR" >&2
    echo "  reconcile those paths manually before retrying" >&2
    return 1
  fi
}

archive_legacy_state() {
  local relative
  legacy_migration_needed || return 0
  preflight_legacy_archive
  mkdir -p "$(dirname "$LEGACY_BACKUP_DIR")"
  mkdir "$LEGACY_BACKUP_DIR"
  cp -p "$AGENT_DIR/settings.json" "$LEGACY_BACKUP_DIR/settings.before.json"
  MIGRATION_PERFORMED=1
  for relative in subagents.json agent-tool-description.md agents; do
    if [ -e "$AGENT_DIR/$relative" ] || [ -L "$AGENT_DIR/$relative" ]; then
      mv "$AGENT_DIR/$relative" "$LEGACY_BACKUP_DIR/"
    fi
  done
  echo "  archive legacy settings and routing assets: $LEGACY_BACKUP_DIR"
}

rollback_legacy_state() {
  local relative
  [ "$MIGRATION_PERFORMED" = 1 ] || return 0
  echo "  rollback legacy settings and routing assets" >&2
  if [ -f "$LEGACY_BACKUP_DIR/settings.before.json" ]; then
    cp -p "$LEGACY_BACKUP_DIR/settings.before.json" "$AGENT_DIR/settings.json"
  fi
  for relative in subagents.json agent-tool-description.md agents; do
    if [ -e "$LEGACY_BACKUP_DIR/$relative" ] || [ -L "$LEGACY_BACKUP_DIR/$relative" ]; then
      rm -rf "$AGENT_DIR/$relative"
      mv "$LEGACY_BACKUP_DIR/$relative" "$AGENT_DIR/$relative"
    fi
  done
  rm -f "$LEGACY_BACKUP_DIR/settings.before.json"
  rmdir "$LEGACY_BACKUP_DIR" 2>/dev/null || true
  MIGRATION_PERFORMED=0
}

legacy_settings_packages() {
  local action="$1"
  node - "$AGENT_DIR/settings.json" "$action" <<'NODE'
const fs = require("node:fs");
const [settingsPath, action] = process.argv.slice(2);

function isLegacy(entry) {
  const source = typeof entry === "string" ? entry : entry?.source;
  if (typeof source !== "string") return false;
  const normalized = source.trim().replace(/\\/g, "/").replace(/\/+$/, "");
  if (/^npm:pi-(?:subagents|herdr)(?:@[^/]*)?$/.test(normalized)) return true;
  const localPath = normalized.replace(/^file:/, "");
  return /(?:^|\/)packages\/pi-(?:subagents|herdr)$/.test(localPath);
}

try {
  const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  const packages = Array.isArray(settings.packages) ? settings.packages : [];
  const found = packages.filter(isLegacy);
  if (action === "check") process.exit(found.length > 0 ? 0 : 1);
  if (action !== "remove") process.exit(2);
  if (found.length === 0) process.exit(0);
  settings.packages = packages.filter((entry) => !isLegacy(entry));
  const temporary = `${settingsPath}.${process.pid}.tmp`;
  const mode = fs.statSync(settingsPath).mode;
  fs.writeFileSync(temporary, `${JSON.stringify(settings, null, 2)}\n`, { mode });
  fs.renameSync(temporary, settingsPath);
  console.log(found.length);
} catch {
  process.exit(1);
}
NODE
}

remove_legacy_settings_packages() {
  local removed
  removed="$(legacy_settings_packages remove)"
  if [ -n "$removed" ]; then
    echo "  remove $removed legacy package entr$( [ "$removed" = 1 ] && printf 'y' || printf 'ies' )"
  fi
}

pi_runtime_matches() {
  local pi_path resolved version
  pi_path="$(command -v "$PI_BIN" 2>/dev/null || true)"
  [ -n "$pi_path" ] || return 1
  resolved="$(node -e 'const fs = require("node:fs"); try { process.stdout.write(fs.realpathSync(process.argv[1])); } catch { process.exit(1); }' "$pi_path" 2>/dev/null || true)"
  case "$resolved" in
    */node_modules/@earendil-works/pi-coding-agent/dist/cli.js) ;;
    *) return 1 ;;
  esac
  version="$("$PI_BIN" --version 2>/dev/null || true)"
  [ "$version" = "$EXPECTED_PI_VERSION" ]
}

settings_has_package() {
  node - "$AGENT_DIR/settings.json" "$PACKAGE_SOURCE" "$PACKAGE_NAME" <<'NODE'
const fs = require("node:fs");
const [settingsPath, expectedSource, packageName] = process.argv.slice(2);
try {
  const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  const identity = `npm:${packageName}`;
  const matching = (settings.packages ?? []).filter((entry) => {
    const source = typeof entry === "string" ? entry : entry?.source;
    return typeof source === "string"
      && (source === identity || source.startsWith(`${identity}@`));
  });
  const activeCanonicalEntry = matching.length === 1
    && typeof matching[0] === "string"
    && matching[0] === expectedSource;
  process.exit(activeCanonicalEntry ? 0 : 1);
} catch {
  process.exit(1);
}
NODE
}

installed_version_matches() {
  node - "$AGENT_DIR/npm/node_modules/$PACKAGE_NAME/package.json" "$PACKAGE_NAME" "$PACKAGE_VERSION" <<'NODE'
const fs = require("node:fs");
const [manifestPath, expectedName, expectedVersion] = process.argv.slice(2);
try {
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  process.exit(manifest.name === expectedName && manifest.version === expectedVersion ? 0 : 1);
} catch {
  process.exit(1);
}
NODE
}

check_installation() {
  local failed=0
  if pi_runtime_matches; then
    echo "  ok   compatible Pi runtime: $EXPECTED_PI_VERSION"
  else
    echo "  FAIL Pi must use npm layout at exact version $EXPECTED_PI_VERSION"
    failed=1
  fi

  if [ ! -f "$AGENT_DIR/settings.json" ]; then
    echo "  MISS Pi settings not found: $AGENT_DIR/settings.json"
    failed=1
  elif settings_has_package; then
    echo "  ok   Pi package configured: $PACKAGE_SOURCE"
  else
    echo "  MISS exact Pi package pin: $PACKAGE_SOURCE"
    failed=1
  fi

  if [ -f "$AGENT_DIR/settings.json" ] && legacy_settings_packages check; then
    echo "  FAIL legacy pi-subagents/pi-herdr package entry remains"
    failed=1
  else
    echo "  ok   legacy package entries absent"
  fi

  if installed_version_matches; then
    echo "  ok   installed package: $PACKAGE_NAME@$PACKAGE_VERSION"
  else
    echo "  MISS installed package version: $PACKAGE_NAME@$PACKAGE_VERSION"
    failed=1
  fi

  if legacy_assets_present; then
    echo "  FAIL active legacy routing assets remain"
    failed=1
  else
    echo "  ok   active legacy routing assets absent"
  fi
  if ! check_routing_assets; then failed=1; fi
  return "$failed"
}

print_plan

case "$MODE" in
  dry-run)
    cat <<EOF

Would:
  1. install $PACKAGE_SOURCE with Pi $EXPECTED_PI_VERSION;
  2. remove legacy pi-subagents/pi-herdr package entries; and
  3. archive active legacy routing assets under $LEGACY_BACKUP_DIR.

No files or Pi settings were changed. Re-run with --apply to install and migrate.
EOF
    ;;
  check)
    echo
    check_installation
    ;;
  apply)
    if ! check_routing_assets; then
      echo "setup-pi-subagents: apply the Pi scaffold before installing the package" >&2
      echo "  ./dot pi scaffold --apply" >&2
      exit 1
    fi
    command -v node >/dev/null 2>&1 || {
      echo "setup-pi-subagents: required command not found: node" >&2
      exit 1
    }
    command -v "$PI_BIN" >/dev/null 2>&1 || {
      echo "setup-pi-subagents: required command not found: $PI_BIN" >&2
      exit 1
    }
    pi_runtime_matches || {
      echo "setup-pi-subagents: Pi must use npm layout at exact version $EXPECTED_PI_VERSION" >&2
      exit 1
    }
    node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && minor < 19)) process.exit(1)' || {
      echo "setup-pi-subagents: Node.js >=22.19.0 is required" >&2
      exit 1
    }

    preflight_legacy_archive
    trap 'rollback_legacy_state' ERR
    archive_legacy_state
    remove_legacy_settings_packages
    PI_CODING_AGENT_DIR="$AGENT_DIR" "$PI_BIN" install "$PACKAGE_SOURCE"
    echo
    if ! check_installation; then
      rollback_legacy_state
      echo "setup-pi-subagents: package was installed but verification failed" >&2
      exit 1
    fi
    trap - ERR
    MIGRATION_PERFORMED=0
    echo "Restart Pi or run /reload before using the new tools."
    echo "Install/check each credential profile separately by setting PI_CODING_AGENT_DIR."
    ;;
esac
