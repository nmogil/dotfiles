#!/usr/bin/env bash
# Integration test for the public Pi Codex subagent installer. Uses a temp HOME
# and a fake global npm Pi to verify the exact package pin and the minimum Pi
# version through `./dot pi subagents`. Uses the private scaffold when one is
# configured, otherwise a minimal public fixture (placeholder routing assets),
# so CI exercises the gates too.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/scripts/lib/local-env.sh"
load_local_env || true
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SCAFFOLD="${DOTFILES_PI_SCAFFOLD_DIR:-$ROOT/templates/pi}"
if [ ! -f "$SCAFFOLD/agent/pi-codex-subagents/SYSTEM.md" ]; then
  SCAFFOLD="$TMP/fixture-scaffold"
  for asset in pi-codex-subagents/SYSTEM.md pi-codex-subagents/config.json \
    pi-codex-subagents/agents/engineer.md pi-codex-subagents/agents/architect.md \
    pi-codex-subagents/agents/analyst.md pi-codex-subagents/agents/reviewer.md \
    pi-codex-subagents/agents/sol-reviewer.md pi-codex-subagents/agents/claude-reviewer.md \
    pi-codex-subagents/agents/writer.md pi-codex-subagents/agents/adjudicator.md \
    pi-codex-subagents/agents/fast.md skills/subagent-routing/SKILL.md \
    skills/coding-agent-account-routing/SKILL.md; do
    mkdir -p "$(dirname "$SCAFFOLD/agent/$asset")"
    printf 'fixture %s\n' "$asset" > "$SCAFFOLD/agent/$asset"
  done
  printf '%s\n' 'using the public fixture scaffold (no private scaffold configured)'
fi
export DOTFILES_PI_SCAFFOLD_DIR="$SCAFFOLD"
. "$ROOT/scripts/lib/pi-cli.sh"
PI_PACKAGE_JSON="$TMP/lib/node_modules/@earendil-works/pi-coding-agent/package.json"
set_pi_version() {  # the fake Pi's version lives in its package.json, as npm installs it
  printf '{"name": "@earendil-works/pi-coding-agent", "version": "%s"}\n' "$1" > "$PI_PACKAGE_JSON"
}

AGENT_DIR="$TMP/.pi/agent"
FAKE_PI="$TMP/bin/pi"
FAKE_PI_TARGET="$TMP/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
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
  echo "the installer must read package.json, not launch pi --version" >&2
  exit 97
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
printf '%s\n' '{"name":"@ogulcancelik/pi-codex-subagents","version":"0.3.5"}' \
  > "$package_dir/package.json"
SH
chmod +x "$FAKE_PI_TARGET"
ln -s "$FAKE_PI_TARGET" "$FAKE_PI"
set_pi_version "$PI_MIN_VERSION"

HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" "$ROOT/dot" pi subagents --apply >/dev/null
HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" "$ROOT/dot" pi subagents --apply >/dev/null
HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" "$ROOT/dot" pi subagents --check >/dev/null

test "$(wc -l < "$CALLS")" -eq 2
test "$(sort -u "$CALLS")" = \
  "install npm:@ogulcancelik/pi-codex-subagents@0.3.5"
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
    "npm:@ogulcancelik/pi-codex-subagents@0.3.5",
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

set_pi_version 0.81.1
if check_output="$(HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" "$ROOT/dot" pi subagents --check 2>&1)"; then
  echo "expected a Pi older than the minimum to fail the check" >&2
  exit 1
fi
printf '%s\n' "$check_output" | grep -Fq "older than the minimum $PI_MIN_VERSION" \
  && printf '%s\n' "$check_output" | grep -Fq "pi update" \
  || { printf '%s\n' "$check_output"; echo "expected the minimum-version failure to say to run pi update" >&2; exit 1; }
# Newer than the minimum is compatible; versions compare numerically.
set_pi_version 99.10.0
check_output="$(HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" "$ROOT/dot" pi subagents --check 2>&1)" \
  || { printf '%s\n' "$check_output"; echo "expected a newer Pi to pass the check" >&2; exit 1; }
printf '%s\n' "$check_output" | grep -Fq "ok   compatible Pi runtime: 99.10.0 (minimum $PI_MIN_VERSION)" \
  || { printf '%s\n' "$check_output"; echo "expected the check to report the installed version and minimum" >&2; exit 1; }
# Unreadable metadata and a project-local install (not global npm) both fail.
set_pi_version 1.6
if check_output="$(HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" "$ROOT/dot" pi subagents --check 2>&1)"; then
  echo "expected unreadable Pi metadata to fail the check" >&2; exit 1
fi
printf '%s\n' "$check_output" | grep -Fq "FAIL Pi version unavailable" \
  || { printf '%s\n' "$check_output"; echo "expected the check to say the Pi version is unavailable" >&2; exit 1; }
printf '{"name": "evil-package", "version": "99.10.0"}\n' > "$PI_PACKAGE_JSON"
if check_output="$(HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$FAKE_PI" \
  PI_TEST_CALLS="$CALLS" "$ROOT/dot" pi subagents --apply 2>&1)"; then
  echo "expected a package.json naming another package to be refused" >&2; exit 1
fi
printf '%s\n' "$check_output" | grep -Fq "must be a global npm install" \
  || { printf '%s\n' "$check_output"; echo "expected a name mismatch to be not-the-install" >&2; exit 1; }
set_pi_version 99.10.0
LOCAL_PI="$TMP/project/node_modules/.bin/pi"
mkdir -p "$TMP/project/node_modules/@earendil-works" "$(dirname "$LOCAL_PI")"
cp -R "$TMP/lib/node_modules/@earendil-works/pi-coding-agent" "$TMP/project/node_modules/@earendil-works/"
ln -s ../@earendil-works/pi-coding-agent/dist/bundle/cli.js "$LOCAL_PI"
if HOME="$TMP" PI_CODING_AGENT_DIR="$AGENT_DIR" PI_BIN="$LOCAL_PI" PI_TEST_CALLS="$CALLS" \
  "$ROOT/dot" pi subagents --apply >/dev/null 2>&1; then
  echo "expected a project-local Pi to be refused" >&2; exit 1
fi
test "$(wc -l < "$CALLS")" -eq 3  # two installs above plus the injected failure; none since
set_pi_version "$PI_MIN_VERSION"

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
    "source": "npm:@ogulcancelik/pi-codex-subagents@0.3.5",
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
printf '%s\n' '#!/usr/bin/env bash' "echo $PI_MIN_VERSION" > "$BAD_PI"
chmod +x "$BAD_PI"
doctor_output="$(HOME="$TMP" DOTFILES_PI_CONFIG_DIR="$TMP/no-pi-config" PATH="$TMP/badbin:$PATH" "$ROOT/dot" pi doctor)"
printf '%s\n' "$doctor_output" | grep -Fq \
  "WARN Pi at $BAD_PI is not the required npm package layout"

printf '%s\n' 'ok   Pi Codex subagent installer migrates legacy state and verifies exact assets and the minimum Pi runtime'
