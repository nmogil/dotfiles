#!/usr/bin/env bash
# Isolated, credential-safety and idempotence tests for Herdr/Hermes config sync.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
export XDG_CONFIG_HOME="$TMP/.config"
export HERMES_HOME="$TMP/.hermes"

# Herdr: install exact portable files, check, and prove drift is detected.
"$ROOT/scripts/setup-herdr-config.sh" --apply >/dev/null
"$ROOT/scripts/setup-herdr-config.sh" --check >/dev/null
printf '\n# drift\n' >> "$XDG_CONFIG_HOME/herdr/config.toml"
if "$ROOT/scripts/setup-herdr-config.sh" --check >/dev/null 2>&1; then
  echo "expected Herdr drift check to fail" >&2
  exit 1
fi
"$ROOT/scripts/setup-herdr-config.sh" --apply >/dev/null
"$ROOT/scripts/setup-herdr-config.sh" --check >/dev/null

# Hermes: preserve local-only MCP/auth-shaped content while applying preferences.
mkdir -p "$HERMES_HOME"
cat > "$HERMES_HOME/config.yaml" <<'YAML'
_config_version: 34
mcp_servers:
  private-example:
    enabled: false
    url: https://private.invalid/mcp
    auth:
      token: local-only-test-token
model:
  provider: old-provider
  default: old-model
YAML
chmod 600 "$HERMES_HOME/config.yaml"
"$ROOT/scripts/setup-hermes-config.sh" --apply >/dev/null
"$ROOT/scripts/setup-hermes-config.sh" --check >/dev/null
"$ROOT/scripts/setup-hermes-config.sh" --apply >/dev/null

python3 - "$HERMES_HOME/config.yaml" <<'PY'
import stat
import sys
from pathlib import Path
import yaml
p = Path(sys.argv[1])
config = yaml.safe_load(p.read_text())
assert config["_config_version"] == 34
assert config["mcp_servers"]["private-example"]["auth"]["token"] == "local-only-test-token"
assert config["model"] == {"provider": "openai-codex", "default": "gpt-5.6-sol"}
assert config["security"]["redact_secrets"] is True
assert config["delegation"]["max_concurrent_children"] == 2
assert config["display"]["skin"] == "pi-screenshot"
assert stat.S_IMODE(p.stat().st_mode) == 0o600
PY

# Public templates must remain endpoint/credential free.
if grep -rIlE 'sk-ant-[A-Za-z0-9]|AKIA[0-9A-Z]{16}|xox[baprs]-|-----BEGIN [A-Z ]*PRIVATE KEY-----|https?://' \
  "$ROOT/templates/hermes" "$ROOT/templates/herdr" | grep -v '/SKILL.md$' >/dev/null; then
  echo "portable agent config template contains secret/endpoint-like data" >&2
  exit 1
fi

printf '%s\n' 'ok   Herdr/Hermes portable configs apply idempotently and preserve local-only state'
