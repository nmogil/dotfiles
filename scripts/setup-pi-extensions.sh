#!/usr/bin/env bash
# Opt-in core extension updates. Pins/config come from the private scaffold;
# permissions, credentials, model selection, and routing templates stay intact.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib/local-env.sh"
load_local_env || true
MODE="${1:---dry-run}"
case "$MODE" in
  --dry-run|--apply|--check) [ "$#" -le 1 ] || exit 2 ;;
  -h|--help)
    echo 'Usage: ./dot pi extensions [--dry-run | --apply | --check]'
    echo 'Personal: update five reviewed core packages and native compaction settings.'
    echo 'Work: update existing core packages and add Anthropic image-cap; no personal footer.'
    exit 0 ;;
  *) echo "Unknown option: $MODE" >&2; exit 2 ;;
esac
PI_ROOT="${PI_HOME:-$HOME/.pi}"
python3 - "$MODE" "${DOTFILES_PI_SCAFFOLD_DIR:-$ROOT/templates/pi}" \
  "${PI_CODING_AGENT_DIR:-$PI_ROOT/agent}" "$PI_ROOT/agent" "${PI_BIN:-pi}" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

mode, scaffold, agent_dir, personal_dir, pi = sys.argv[1:]
scaffold, agent = Path(scaffold), Path(agent_dir)
settings_path = agent / "settings.json"
template = json.loads((scaffold / "agent/settings.example.json").read_text())
settings = json.loads(settings_path.read_text())
packages = settings.get("packages", [])
if not isinstance(packages, list):
    raise SystemExit("settings.packages must be an array")
names = ["pi-minimal-footer", "pi-session-recall", "pi-codex-subagents",
         "pi-codex-compaction", "pi-anthropic-image-cap"]
configured = {entry if isinstance(entry, str) else entry.get("source", "")
              for entry in packages if isinstance(entry, (str, dict))}
personal = agent.resolve() == Path(personal_dir).resolve()
expected = {}
for name in names:
    identity = f"npm:@ogulcancelik/{name}"
    existing = [source for source in configured
                if source == identity or source.startswith(identity + "@")]
    if not personal and not existing and name != "pi-anthropic-image-cap":
        continue
    pins = [source for source in template["packages"]
            if isinstance(source, str) and re.fullmatch(re.escape(identity) + r"@\d+\.\d+\.\d+", source)]
    if len(pins) != 1:
        raise SystemExit(f"Missing or ambiguous reviewed pin: {name}")
    if sum(isinstance(entry, str) and (entry == identity or entry.startswith(identity + "@"))
           for entry in packages) > 1:
        raise SystemExit(f"Duplicate package identity: {name}; reconcile before updating")
    if any(isinstance(entry, dict) and entry.get("source") in existing for entry in packages):
        raise SystemExit(f"Reconcile resource filters manually before updating {name}")
    expected[name] = pins[0]

compaction = template["compaction"] if personal and "pi-codex-compaction" in expected else {}
if settings.get("compaction") is not None and not isinstance(settings["compaction"], dict):
    raise SystemExit("settings.compaction must be an object")
changes = []
failed = False
print(f"== Pi core extensions: {mode}, {agent} ==", flush=True)
for name, source in expected.items():
    manifest = agent / "npm/node_modules/@ogulcancelik" / name / "package.json"
    installed = json.loads(manifest.read_text()).get("version") if manifest.exists() else None
    matches = [entry for entry in packages if entry == source]
    identity = source.rsplit("@", 1)[0]
    same_identity = [entry for entry in packages if isinstance(entry, str)
                     and (entry == identity or entry.startswith(identity + "@"))]
    ready = installed == source.rsplit("@", 1)[1] and matches == same_identity and len(matches) == 1
    print(f"  {'ok' if ready else 'update'} {source}", flush=True)
    if not ready:
        changes.append(source)
        failed = True
config_change = any(settings.get("compaction", {}).get(key) != value
                    for key, value in compaction.items())
if compaction:
    print(f"  {'update' if config_change else 'ok'} native compaction settings", flush=True)
example_path = agent / "settings.example.json"
example_source = scaffold / "agent/settings.example.json"
example_change = personal and (not example_path.exists() or example_path.read_bytes() != example_source.read_bytes())
failed |= config_change or example_change
if mode == "--check":
    raise SystemExit(1 if failed else 0)
if mode == "--dry-run" or not failed:
    raise SystemExit(0)

expected_pi = json.loads((scaffold / "package.json").read_text())["dependencies"]["@earendil-works/pi-coding-agent"]
pi_path = Path(shutil.which(pi) or pi).resolve()
if not re.search(r"/node_modules/@earendil-works/pi-coding-agent/dist/(?:bundle/)?cli\.js$", str(pi_path)) or "/.vite-plus/" in str(pi_path):
    raise SystemExit("Pi must use the npm layout; run ./dot pi install first")
if subprocess.check_output([pi, "--version"], text=True).strip() != expected_pi:
    raise SystemExit(f"Run ./dot pi install first (requires Pi {expected_pi})")
backups = agent / "backups"
backups.mkdir(parents=True, exist_ok=True)
backup = Path(tempfile.mkdtemp(prefix="pi-core-", dir=backups))
shutil.copy2(settings_path, backup / "settings.json")
if example_path.exists() and personal:
    shutil.copy2(example_path, backup / "settings.example.json")
print(f"  backup: {backup}", flush=True)
env = {**os.environ, "PI_CODING_AGENT_DIR": str(agent)}
for source in changes:
    subprocess.run([pi, "install", source], env=env, check=True)
if config_change:
    # Re-read after Pi installs so their package declarations are not overwritten.
    settings = json.loads(settings_path.read_text())
    settings["compaction"] = {**settings.get("compaction", {}), **compaction}
    fd, temporary = tempfile.mkstemp(dir=agent, prefix=".settings-")
    try:
        os.fchmod(fd, settings_path.stat().st_mode & 0o777)
        with os.fdopen(fd, "w") as output:
            json.dump(settings, output, indent=2)
            output.write("\n")
        os.replace(temporary, settings_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
if example_change:
    shutil.copy2(example_source, example_path)
print("Restart Pi or run /reload to load the updated extensions.", flush=True)
PY
