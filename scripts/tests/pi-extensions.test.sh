#!/usr/bin/env bash
# Exercise the real dot entrypoint with isolated settings and a fake global npm
# Pi. Uses the private scaffold when one is configured, otherwise a minimal
# public fixture with the same reviewed package pins, so CI runs it too.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/scripts/lib/local-env.sh"
load_local_env || true
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SCAFFOLD="${DOTFILES_PI_SCAFFOLD_DIR:-$ROOT/templates/pi}"
if [ ! -f "$SCAFFOLD/agent/settings.example.json" ]; then
  . "$ROOT/scripts/lib/pi-cli.sh"
  SCAFFOLD="$TMP/fixture-scaffold"
  mkdir -p "$SCAFFOLD/agent"
  printf '{"private": true, "dependencies": {"%s": "%s"}}\n' "$PI_PACKAGE" "$PI_MIN_VERSION" > "$SCAFFOLD/package.json"
  cat > "$SCAFFOLD/agent/settings.example.json" <<'JSON'
{
  "packages": [
    "npm:@ogulcancelik/pi-minimal-footer@0.1.10",
    "npm:@ogulcancelik/pi-session-recall@1.0.8",
    "npm:@ogulcancelik/pi-auto-permissions@0.1.3",
    "npm:@ogulcancelik/pi-anthropic-image-cap@0.2.0",
    "npm:@ogulcancelik/pi-codex-subagents@0.3.5",
    "npm:@ogulcancelik/pi-codex-compaction"
  ],
  "compaction": { "reserveTokens": 27200, "keepRecentTokens": 20000 }
}
JSON
  echo 'using the public fixture scaffold (no private scaffold configured)'
fi
export DOTFILES_PI_SCAFFOLD_DIR="$SCAFFOLD"
: > "$TMP/empty.env"
export DOTFILES_LOCAL_ENV="$TMP/empty.env" PI_HOME="$TMP/.pi"
# A global npm install: <prefix>/bin/pi -> ../lib/node_modules/<pkg>/dist/bundle/cli.js.
PI_CLI="$TMP/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
PI_PACKAGE_JSON="$TMP/lib/node_modules/@earendil-works/pi-coding-agent/package.json"
export PI_BIN="$TMP/bin/pi" PI_TEST_CALLS="$TMP/calls"
set_pi_version() {
  printf '{"name": "@earendil-works/pi-coding-agent", "version": "%s"}\n' "$1" > "$PI_PACKAGE_JSON"
}
# The scaffold's Pi dependency is the minimum; the fake Pi starts there.
PI_MINIMUM="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["dependencies"]["@earendil-works/pi-coding-agent"])' "$SCAFFOLD/package.json")"
AGENT="$PI_HOME/agent"
export PI_CODING_AGENT_DIR="$AGENT"
mkdir -p "$AGENT" "$(dirname "$PI_CLI")" "$TMP/bin"
printf '%s\n' '{"packages":["npm:@ogulcancelik/pi-auto-permissions@0.1.3","npm:keep-me@1.2.3"],"theme":"keep-me","compaction":{"modelOverrides":{"custom/model":{"reserveTokens":123}}}}' > "$AGENT/settings.json"
cp "$AGENT/settings.json" "$TMP/before.json"
cat > "$PI_CLI" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = --version ]; then echo 'read package.json; do not launch pi --version' >&2; exit 97; fi
[ "$1" = install ] || exit 2
[ "${PI_TEST_FAIL_INSTALL:-0}" != 1 ] || exit 42
printf '%s\n' "$2" >> "$PI_TEST_CALLS"
python3 - "$PI_CODING_AGENT_DIR" "$2" <<'PY'
import json
import sys
from pathlib import Path
agent, source = Path(sys.argv[1]), sys.argv[2]
if source == "npm:@ogulcancelik/pi-codex-compaction":
    identity, version = source, "0.1.7"
else:
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
chmod +x "$PI_CLI"
ln -s ../lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js "$PI_BIN"
set_pi_version "$PI_MINIMUM"

dry_run="$("$ROOT/dot" pi extensions --dry-run)"
printf '%s\n' "$dry_run" | grep -Fq "$AGENT"
cmp "$TMP/before.json" "$AGENT/settings.json"
test ! -e "$PI_TEST_CALLS"
test ! -e "$AGENT/backups"
if "$ROOT/dot" pi extensions --check >/dev/null; then
  echo 'expected missing extension pins to fail check' >&2; exit 1
fi
# A Pi older than the minimum is refused before anything is installed.
set_pi_version 0.0.1
if older_out="$("$ROOT/dot" pi extensions --apply 2>&1)"; then
  echo 'expected a Pi older than the minimum to be refused' >&2; exit 1
fi
printf '%s\n' "$older_out" | grep -Fq "Pi 0.0.1 is older than the minimum $PI_MINIMUM" \
  && printf '%s\n' "$older_out" | grep -Fq 'pi update' \
  || { printf '%s\n' "$older_out"; echo 'expected the refusal to name the minimum and pi update' >&2; exit 1; }
test ! -e "$PI_TEST_CALLS"
cmp "$TMP/before.json" "$AGENT/settings.json"
set_pi_version 1.0
if "$ROOT/dot" pi extensions --apply >/dev/null 2>&1; then
  echo 'expected an unparsable Pi version to be refused' >&2; exit 1
fi
test ! -e "$PI_TEST_CALLS"
# The Pi CLI itself (not a global npm bin) is not a supported install.
set_pi_version "$PI_MINIMUM"
if PI_BIN="$PI_CLI" "$ROOT/dot" pi extensions --apply >/dev/null 2>&1; then
  echo 'expected a Pi outside <prefix>/bin to be refused' >&2; exit 1
fi
test ! -e "$PI_TEST_CALLS"
# Newer than the minimum is accepted (numeric compare: minor + 10).
newer="$(python3 -c 'import sys; a, b, c = map(int, sys.argv[1].split(".")); print(f"{a}.{b + 10}.0")' "$PI_MINIMUM")"
set_pi_version "$newer"
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
    "npm:@ogulcancelik/pi-anthropic-image-cap@0.2.0",
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
printf '%s\n' '#!/usr/bin/env bash' "echo $PI_MINIMUM" > "$TMP/not-npm-pi"
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
assert "npm:@ogulcancelik/pi-codex-compaction" in settings["packages"]
assert settings["compaction"] == {"enabled": False, "reserveTokens": 123, "custom": "keep"}
PY
test "$(wc -l < "$PI_TEST_CALLS")" -eq 8
# A future installed compaction release must not be downgraded or repinned.
printf '%s\n' '{"version":"0.1.8"}' > "$AGENT/npm/node_modules/@ogulcancelik/pi-codex-compaction/package.json"
"$ROOT/dot" pi extensions --apply >/dev/null
"$ROOT/dot" pi extensions --check >/dev/null
test "$(wc -l < "$PI_TEST_CALLS")" -eq 8
echo 'ok   core extension updates need Pi >= the scaffold minimum, are opt-in, idempotent, backed up, profile-safe, and keep compaction floating'
