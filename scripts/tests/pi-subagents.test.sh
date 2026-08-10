#!/usr/bin/env bash
# Integration test for the public Pi Codex subagent installer. Uses a temp HOME
# and a fake Pi CLI to verify the exact package pin through `./dot pi subagents`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/scripts/lib/local-env.sh"
load_local_env || true
SCAFFOLD="${DOTFILES_PI_SCAFFOLD_DIR:-$ROOT/templates/pi}"
if [ ! -f "$SCAFFOLD/agent/pi-codex-subagents/SYSTEM.md" ]; then
  printf '%s\n' 'skip Pi subagents test (no scaffold source; set DOTFILES_PI_SCAFFOLD_DIR)'
  exit 0
fi
export DOTFILES_PI_SCAFFOLD_DIR="$SCAFFOLD"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AGENT_DIR="$TMP/.pi/agent"
FAKE_PI="$TMP/bin/pi"
FAKE_PI_TARGET="$TMP/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
CALLS="$TMP/pi-calls.log"
mkdir -p "$TMP/bin" "$(dirname "$FAKE_PI_TARGET")" \
  "$AGENT_DIR/pi-codex-subagents" \
  "$AGENT_DIR/skills/subagent-routing" \
  "$AGENT_DIR/skills/coding-agent-account-routing" \
  "$AGENT_DIR/agents"

cp -R "$SCAFFOLD/agent/pi-codex-subagents/." \
  "$AGENT_DIR/pi-codex-subagents/"
cp "$SCAFFOLD/agent/skills/subagent-routing/SKILL.md" \
  "$AGENT_DIR/skills/subagent-routing/SKILL.md"
cp "$SCAFFOLD/agent/skills/coding-agent-account-routing/SKILL.md" \
  "$AGENT_DIR/skills/coding-agent-account-routing/SKILL.md"

cat > "$AGENT_DIR/settings.json" <<'JSON'
{
  "packages": [
    "/tmp/threeonefour-7f86a2931f83b/packages/pi-subagents",
    "/opt/custom-delegator/packages/pi-herdr",
    { "source": "npm:pi-herdr@0.0.0" },
    "npm:@acme/pi-subagents@1.0.0"
  ]
}
JSON
printf '%s\n' '{"legacy":true}' > "$AGENT_DIR/subagents.json"
printf '%s\n' 'legacy tool description' > "$AGENT_DIR/agent-tool-description.md"
printf '%s\n' 'legacy agent' > "$AGENT_DIR/agents/engineer.md"

cat > "$FAKE_PI_TARGET" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${PI_CODING_AGENT_DIR:?}"
: "${PI_TEST_CALLS:?}"
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' "${PI_TEST_VERSION:-0.84.1}"
  exit 0
fi
printf '%s\n' "$*" >> "$PI_TEST_CALLS"
[ "${1:-}" = install ] || { echo "unsupported fake Pi command" >&2; exit 2; }
[ "${PI_TEST_FAIL_INSTALL:-0}" = 1 ] && exit 42
source_spec="${2:?missing package source}"
settings="$PI_CODING_AGENT_DIR/settings.json"
python3 - "$settings" "$source_spec" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = sys.argv[2]
data = json.loads(path.read_text())
packages = data.setdefault("packages", [])
identity = "npm:@ogulcancelik/pi-codex-subagents"
packages[:] = [
    entry for entry in packages
    if not (isinstance(entry, str) and (entry == identity or entry.startswith(identity + "@")))
]
packages.append(source)
path.write_text(json.dumps(data, indent=2) + "\n")
PY
package_dir="$PI_CODING_AGENT_DIR/npm/node_modules/@ogulcancelik/pi-codex-subagents"
mkdir -p "$package_dir"
printf '%s\n' '{"name":"@ogulcancelik/pi-codex-subagents","version":"0.3.2"}' \
  > "$package_dir/package.json"
SH
chmod +x "$FAKE_PI_TARGET"
ln -s "$FAKE_PI_TARGET" "$FAKE_PI"

HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" "$ROOT/dot" pi subagents --apply >/dev/null
HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" "$ROOT/dot" pi subagents --apply >/dev/null
HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" "$ROOT/dot" pi subagents --check >/dev/null

test "$(wc -l < "$CALLS")" -eq 2
test "$(sort -u "$CALLS")" = \
  "install npm:@ogulcancelik/pi-codex-subagents@0.3.2"
test ! -e "$AGENT_DIR/subagents.json"
test ! -e "$AGENT_DIR/agent-tool-description.md"
test ! -e "$AGENT_DIR/agents"
test -f "$AGENT_DIR/migrations/pi-subagents-legacy/subagents.json"
test -f "$AGENT_DIR/migrations/pi-subagents-legacy/agent-tool-description.md"
test -f "$AGENT_DIR/migrations/pi-subagents-legacy/agents/engineer.md"
test -f "$AGENT_DIR/migrations/pi-subagents-legacy/settings.before.json"
python3 - "$AGENT_DIR/settings.json" \
  "$AGENT_DIR/migrations/pi-subagents-legacy/settings.before.json" <<'PY'
import json
import sys
from pathlib import Path

settings = json.loads(Path(sys.argv[1]).read_text())
backup = json.loads(Path(sys.argv[2]).read_text())
assert settings["packages"] == [
    "npm:@acme/pi-subagents@1.0.0",
    "npm:@ogulcancelik/pi-codex-subagents@0.3.2",
]
assert "/tmp/threeonefour-7f86a2931f83b/packages/pi-subagents" in backup["packages"]
assert "/opt/custom-delegator/packages/pi-herdr" in backup["packages"]
assert {"source": "npm:pi-herdr@0.0.0"} in backup["packages"]
PY

# A failed package install must restore the original settings and routing assets.
FAIL_AGENT="$TMP/.pi/agent-failure"
mkdir -p "$FAIL_AGENT/pi-codex-subagents" \
  "$FAIL_AGENT/skills/subagent-routing" \
  "$FAIL_AGENT/skills/coding-agent-account-routing" \
  "$FAIL_AGENT/agents"
cp -R "$SCAFFOLD/agent/pi-codex-subagents/." "$FAIL_AGENT/pi-codex-subagents/"
cp "$SCAFFOLD/agent/skills/subagent-routing/SKILL.md" \
  "$FAIL_AGENT/skills/subagent-routing/SKILL.md"
cp "$SCAFFOLD/agent/skills/coding-agent-account-routing/SKILL.md" \
  "$FAIL_AGENT/skills/coding-agent-account-routing/SKILL.md"
printf '%s\n' '{"packages":["npm:pi-herdr@0.0.0"]}' > "$FAIL_AGENT/settings.json"
printf '%s\n' '{"legacy":true}' > "$FAIL_AGENT/subagents.json"
printf '%s\n' 'legacy tool description' > "$FAIL_AGENT/agent-tool-description.md"
printf '%s\n' 'legacy agent' > "$FAIL_AGENT/agents/engineer.md"
if HOME="$TMP" PI_CODING_AGENT_DIR="$FAIL_AGENT" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" PI_TEST_FAIL_INSTALL=1 \
  "$ROOT/dot" pi subagents --apply >/dev/null 2>&1; then
  echo "expected injected Pi package-install failure" >&2
  exit 1
fi
grep -Fq 'npm:pi-herdr@0.0.0' "$FAIL_AGENT/settings.json"
test -f "$FAIL_AGENT/subagents.json"
test -f "$FAIL_AGENT/agent-tool-description.md"
test -f "$FAIL_AGENT/agents/engineer.md"
test ! -e "$FAIL_AGENT/migrations/pi-subagents-legacy"

cp "$AGENT_DIR/pi-codex-subagents/SYSTEM.md" "$TMP/SYSTEM.md"
printf '%s\n' 'tampered' >> "$AGENT_DIR/pi-codex-subagents/SYSTEM.md"
if HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" "$ROOT/dot" pi subagents --check >/dev/null 2>&1; then
  echo "expected stale routing asset check to fail" >&2
  exit 1
fi
mv "$TMP/SYSTEM.md" "$AGENT_DIR/pi-codex-subagents/SYSTEM.md"

if HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_VERSION="0.81.1" PI_TEST_CALLS="$CALLS" \
  "$ROOT/dot" pi subagents --check >/dev/null 2>&1; then
  echo "expected incompatible Pi version check to fail" >&2
  exit 1
fi

python3 - "$AGENT_DIR/settings.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
settings = json.loads(path.read_text())
settings["packages"].append("npm:@ogulcancelik/pi-codex-subagents@0.3.1")
path.write_text(json.dumps(settings, indent=2) + "\n")
PY
if HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" "$ROOT/dot" pi subagents --check >/dev/null 2>&1; then
  echo "expected duplicate subagent package identity check to fail" >&2
  exit 1
fi

python3 - "$AGENT_DIR/settings.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
settings = json.loads(path.read_text())
settings["packages"] = [
    entry for entry in settings["packages"]
    if entry != "npm:@ogulcancelik/pi-codex-subagents@0.3.1"
]
settings["packages"][-1] = {
    "source": "npm:@ogulcancelik/pi-codex-subagents@0.3.2",
    "extensions": [],
}
path.write_text(json.dumps(settings, indent=2) + "\n")
PY
if HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" "$ROOT/dot" pi subagents --check >/dev/null 2>&1; then
  echo "expected disabled subagent extension check to fail" >&2
  exit 1
fi

BAD_PI="$TMP/badbin/pi"
mkdir -p "$(dirname "$BAD_PI")"
printf '%s\n' '#!/usr/bin/env bash' 'echo 0.84.1' > "$BAD_PI"
chmod +x "$BAD_PI"
doctor_output="$(HOME="$TMP" PATH="$TMP/badbin:$PATH" "$ROOT/dot" pi doctor)"
printf '%s\n' "$doctor_output" | grep -Fq \
  'WARN Pi 0.84.1 is not the required npm package layout'

printf '%s\n' 'ok   Pi Codex subagent installer migrates legacy state and verifies exact assets/runtime'
