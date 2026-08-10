#!/usr/bin/env bash
# Merge credential-free Hermes preferences into ~/.hermes/config.yaml.
# Unknown/local keys are preserved; secrets and runtime state are never copied.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/templates/hermes/config.portable.yaml"
DEST="${HERMES_HOME:-$HOME/.hermes}/config.yaml"
MODE="dry-run"

usage() {
  cat <<'EOF'
Usage: scripts/setup-hermes-config.sh [--dry-run | --apply | --check]

  --dry-run  Report portable preference drift; write nothing (default).
  --apply    Deep-merge portable preferences, preserving local-only keys.
  --check    Exit non-zero when any portable preference differs.

Never copies .env, auth, gateway identities, MCP servers, sessions, memories,
plugins' runtime data, or caches.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE="dry-run" ;;
    --apply) MODE="apply" ;;
    --check) MODE="check" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "setup-hermes-config: unknown flag: $arg" >&2; usage; exit 2 ;;
  esac
done

[ -f "$SRC" ] || { echo "setup-hermes-config: missing template: $SRC" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "setup-hermes-config: python3 is required" >&2; exit 1; }

python3 - "$MODE" "$SRC" "$DEST" <<'PY'
import os
import re
import shutil
import stat
import sys
import tempfile
from datetime import datetime

try:
    import yaml
except ImportError:
    raise SystemExit("setup-hermes-config: PyYAML is required (install python3-yaml)")

mode, source_path, dest_path = sys.argv[1:]
with open(source_path, encoding="utf-8") as f:
    portable = yaml.safe_load(f) or {}

forbidden_roots = {
    "mcp_servers", "gateway", "dashboard", "secrets", "providers",
    "telegram", "slack", "discord", "matrix", "mattermost",
}
forbidden_key = re.compile(
    r"(?:api[_-]?key|token|secret|password|credential|auth|cookie|webhook|"
    r"allowed[_-]?(?:users|chats|channels)|chat[_-]?id|phone|email|base[_-]?url|url)$",
    re.IGNORECASE,
)

def validate(node, path=()):
    if isinstance(node, dict):
        for key, value in node.items():
            key_s = str(key)
            if not path and key_s in forbidden_roots:
                raise SystemExit(f"setup-hermes-config: forbidden portable root: {key_s}")
            if forbidden_key.search(key_s):
                raise SystemExit(f"setup-hermes-config: forbidden portable key: {'.'.join(path + (key_s,))}")
            validate(value, path + (key_s,))
    elif isinstance(node, list):
        for value in node:
            validate(value, path + ("[]",))
    elif isinstance(node, str):
        if "://" in node or re.search(r"(?i)(?:sk-|xox.|bearer\s|api[_-]?key|token=)", node):
            raise SystemExit(f"setup-hermes-config: secret/endpoint-like portable value at {'.'.join(path)}")

validate(portable)

if os.path.exists(dest_path):
    with open(dest_path, encoding="utf-8") as f:
        current = yaml.safe_load(f) or {}
else:
    current = {}

if not isinstance(current, dict):
    raise SystemExit(f"setup-hermes-config: existing config is not a YAML mapping: {dest_path}")

missing = []
def compare(expected, actual, path=()):
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            missing.append(".".join(path) or "<root>")
            return
        for key, value in expected.items():
            if key not in actual:
                missing.append(".".join(path + (str(key),)))
            else:
                compare(value, actual[key], path + (str(key),))
    elif expected != actual:
        missing.append(".".join(path))

compare(portable, current)
if mode in {"dry-run", "check"}:
    if missing:
        print(f"Hermes portable config drift: {len(missing)} key(s)")
        for path in missing:
            print(f"  drift {path}")
        raise SystemExit(1 if mode == "check" else 0)
    print("Hermes portable config matches")
    raise SystemExit(0)

def merge(base, overlay):
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value
    return base

if not missing:
    print("Hermes portable config already matches")
    raise SystemExit(0)

merged = merge(current, portable)
os.makedirs(os.path.dirname(dest_path), mode=0o700, exist_ok=True)
if os.path.exists(dest_path):
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = f"{dest_path}.backup.{stamp}"
    shutil.copy2(dest_path, backup)
    print(f"Backed up existing config: {backup}")
    file_mode = stat.S_IMODE(os.stat(dest_path).st_mode)
else:
    file_mode = 0o600

fd, temporary = tempfile.mkstemp(prefix=".config.", suffix=".tmp", dir=os.path.dirname(dest_path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        yaml.safe_dump(merged, f, sort_keys=False, allow_unicode=True)
    os.chmod(temporary, file_mode)
    os.replace(temporary, dest_path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print(f"Applied Hermes portable config: {dest_path}")
PY
