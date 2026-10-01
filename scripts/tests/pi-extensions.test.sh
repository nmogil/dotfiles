#!/usr/bin/env bash
# Exercise the real dot entrypoint with isolated settings and a fake Pi installer.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/scripts/lib/local-env.sh"
load_local_env || true
SCAFFOLD="${DOTFILES_PI_SCAFFOLD_DIR:-$ROOT/templates/pi}"
if [ ! -f "$SCAFFOLD/agent/settings.example.json" ]; then
  echo 'skip Pi extensions test (no scaffold source)'
  exit 0
fi
export DOTFILES_PI_SCAFFOLD_DIR="$SCAFFOLD"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/empty.env"
export DOTFILES_LOCAL_ENV="$TMP/empty.env" PI_HOME="$TMP/.pi"
export PI_BIN="$TMP/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js" PI_TEST_CALLS="$TMP/calls"
AGENT="$PI_HOME/agent"
export PI_CODING_AGENT_DIR="$AGENT"
mkdir -p "$AGENT" "$(dirname "$PI_BIN")"
printf '%s\n' '{"packages":["npm:@ogulcancelik/pi-auto-permissions@0.1.3","npm:keep-me@1.2.3"],"theme":"keep-me","compaction":{"modelOverrides":{"custom/model":{"reserveTokens":123}}}}' > "$AGENT/settings.json"
cp "$AGENT/settings.json" "$TMP/before.json"
cat > "$PI_BIN" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = --version ]; then echo 0.99.2; exit 0; fi
[ "$1" = install ] || exit 2
[ "${PI_TEST_FAIL_INSTALL:-0}" != 1 ] || exit 42
printf '%s\n' "$2" >> "$PI_TEST_CALLS"
python3 - "$PI_CODING_AGENT_DIR" "$2" <<'PY'
import json
import sys
from pathlib import Path
agent, source = Path(sys.argv[1]), sys.argv[2]
identity, version = source.rsplit("@", 1)
settings_path = agent / "settings.json"
settings = json.loads(settings_path.read_text())
settings["packages"] = [entry for entry in settings.get("packages", [])
                        if not (isinstance(entry, str) and
                                (entry == identity or entry.startswith(identity + "@")))] + [source]
settings_path.write_text(json.dumps(settings, indent=2) + "\n")
package = agent / "npm/node_modules" / identity.removeprefix("npm:")
package.mkdir(parents=True, exist_ok=True)
(package / "package.json").write_text(json.dumps({"version": version}))
PY
SH
chmod +x "$PI_BIN"

dry_run="$("$ROOT/dot" pi extensions --dry-run)"
printf '%s\n' "$dry_run" | grep -Fq "$AGENT"
cmp "$TMP/before.json" "$AGENT/settings.json"
test ! -e "$PI_TEST_CALLS"
test ! -e "$AGENT/backups"
if "$ROOT/dot" pi extensions --check >/dev/null; then
  echo 'expected missing extension pins to fail check' >&2; exit 1
fi
"$ROOT/dot" pi extensions --apply >/dev/null
"$ROOT/dot" pi extensions --apply >/dev/null
"$ROOT/dot" pi extensions --check >/dev/null
test "$(wc -l < "$PI_TEST_CALLS")" -eq 5
python3 - "$AGENT" "$TMP/before.json" <<'PY'
import json
import sys
from pathlib import Path
agent = Path(sys.argv[1])
settings = json.loads((agent / "settings.json").read_text())
assert settings["theme"] == "keep-me"
assert "npm:@ogulcancelik/pi-auto-permissions@0.1.3" in settings["packages"]
assert "npm:keep-me@1.2.3" in settings["packages"]
assert settings["compaction"]["reserveTokens"] == 27200
assert settings["compaction"]["modelOverrides"] == {"custom/model": {"reserveTokens": 123}}
backups = list((agent / "backups").glob("pi-core-*/settings.json"))
assert len(backups) == 1
assert backups[0].read_bytes() == Path(sys.argv[2]).read_bytes()
PY

WORK="$PI_HOME/agent-clientx"
mkdir -p "$WORK"
ln -s "$AGENT/npm" "$WORK/npm"
printf '%s\n' '{"packages":["npm:@ogulcancelik/pi-codex-subagents@0.3.2"],"defaultProvider":"anthropic"}' > "$WORK/settings.json"
PI_CODING_AGENT_DIR="$WORK" "$ROOT/dot" pi extensions --apply >/dev/null
PI_CODING_AGENT_DIR="$WORK" "$ROOT/dot" pi extensions --check >/dev/null
python3 - "$WORK/settings.json" <<'PY'
import json
import sys
from pathlib import Path
settings = json.loads(Path(sys.argv[1]).read_text())
assert settings == {"defaultProvider": "anthropic", "packages": [
    "npm:@ogulcancelik/pi-codex-subagents@0.3.5",
    "npm:@ogulcancelik/pi-anthropic-image-cap@0.1.0",
]}
PY

FAIL="$PI_HOME/agent-failure"
mkdir -p "$FAIL"
printf '%s\n' '{}' > "$FAIL/settings.json"
if PI_CODING_AGENT_DIR="$FAIL" PI_TEST_FAIL_INSTALL=1 "$ROOT/dot" pi extensions --apply >/dev/null 2>&1; then
  echo 'expected failed package installation to stop apply' >&2; exit 1
fi
test "$(< "$FAIL/settings.json")" = '{}'
test "$(wc -l < "$PI_TEST_CALLS")" -eq 7

printf '%s\n' '{"packages":[{"source":"npm:@ogulcancelik/pi-codex-subagents@0.3.2","extensions":[]}]}' > "$FAIL/settings.json"
if PI_CODING_AGENT_DIR="$FAIL" "$ROOT/dot" pi extensions --apply >/dev/null 2>&1; then
  echo 'expected resource filters to require manual reconciliation' >&2; exit 1
fi
test "$(wc -l < "$PI_TEST_CALLS")" -eq 7

printf '%s\n' '{"packages":["npm:@ogulcancelik/pi-codex-subagents@0.3.2","npm:@ogulcancelik/pi-codex-subagents@0.3.5"]}' > "$FAIL/settings.json"
if PI_CODING_AGENT_DIR="$FAIL" "$ROOT/dot" pi extensions --apply >/dev/null 2>&1; then
  echo 'expected duplicate identities to require reconciliation' >&2; exit 1
fi
test "$(wc -l < "$PI_TEST_CALLS")" -eq 7

printf '%s\n' '{}' > "$FAIL/settings.json"
printf '%s\n' '#!/usr/bin/env bash' 'echo 0.99.2' > "$TMP/not-npm-pi"
chmod +x "$TMP/not-npm-pi"
if PI_CODING_AGENT_DIR="$FAIL" PI_BIN="$TMP/not-npm-pi" "$ROOT/dot" pi extensions --apply >/dev/null 2>&1; then
  echo 'expected non-npm Pi layout to be rejected' >&2; exit 1
fi
test "$(wc -l < "$PI_TEST_CALLS")" -eq 7
python3 - "$WORK/settings.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
settings = json.loads(path.read_text())
settings["packages"].append("npm:@ogulcancelik/pi-codex-compaction@0.1.1")
settings["compaction"] = {"enabled": False, "reserveTokens": 123, "custom": "keep"}
path.write_text(json.dumps(settings))
PY
PI_CODING_AGENT_DIR="$WORK" "$ROOT/dot" pi extensions --apply >/dev/null
PI_CODING_AGENT_DIR="$WORK" "$ROOT/dot" pi extensions --check >/dev/null
python3 - "$WORK/settings.json" <<'PY'
import json
import sys
from pathlib import Path
settings = json.loads(Path(sys.argv[1]).read_text())
assert "npm:@ogulcancelik/pi-codex-compaction@0.1.5" in settings["packages"]
assert settings["compaction"] == {"enabled": False, "reserveTokens": 123, "custom": "keep"}
PY
test "$(wc -l < "$PI_TEST_CALLS")" -eq 8
echo 'ok   core extension updates are opt-in, idempotent, backed up, and profile-safe'
