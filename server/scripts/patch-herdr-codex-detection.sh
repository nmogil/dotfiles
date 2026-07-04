#!/bin/bash
# Patch Herdr's cached Codex detection manifest so the Codex
# "Update available ... Press enter to continue" and
# "Hooks need review ... press enter to confirm" screens classify as
# blocked (needs attention) instead of idle.
#
# Idempotent — safe to re-run any time. Note: Herdr overwrites this cache
# when it refreshes remote manifests (e.g. `herdr server
# update-agent-manifests`), so re-run this script after an update if the
# rules disappear upstream.
set -euo pipefail

MANIFEST="$HOME/.local/state/herdr/agent-detection/remote/codex.toml"

if [ ! -f "$MANIFEST" ]; then
    echo "skip: $MANIFEST not found (Herdr hasn't cached agent manifests yet — start Herdr once, then re-run)"
    exit 0
fi

python3 - "$MANIFEST" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

rules = {
    "codex_update_prompt": """[[rules]]
id = \"codex_update_prompt\"
state = \"blocked\"
priority = 960
region = \"whole_recent\"
visible_blocker = true
contains = [\"update available\", \"press enter to continue\"]
""",
    "codex_hooks_review_prompt": """[[rules]]
id = \"codex_hooks_review_prompt\"
state = \"blocked\"
priority = 955
region = \"whole_recent\"
visible_blocker = true
contains = [\"hooks need review\", \"press enter to confirm\"]
""",
}

# Remove stale copies of the managed rules, regardless of where a previous run
# inserted them. Then insert the canonical blocks ahead of live_strong_blocker
# so they are easy to inspect near the other blocker rules. Priority still
# controls matching if Herdr reorders internally.
for rule_id in rules:
    text = re.sub(
        rf"\n?\[\[rules\]\]\n(?:[^[]|\[(?!\[rules\]\]))*?id = \"{re.escape(rule_id)}\"(?:[^[]|\[(?!\[rules\]\]))*(?=\n\[\[rules\]\]|\Z)",
        "",
        text,
        flags=re.MULTILINE,
    )

block = "\n" + "\n".join(rules.values()).rstrip() + "\n"
anchor = '\n[[rules]]\nid = "live_strong_blocker"'
if anchor in text:
    text = text.replace(anchor, block + anchor, 1)
else:
    text = text.rstrip() + block

path.write_text(text)
print("ok: installed/updated managed Codex blocker rules")
PY

HERDR_BIN="$(command -v herdr || true)"
[ -z "$HERDR_BIN" ] && [ -x "$HOME/.local/bin/herdr" ] && HERDR_BIN="$HOME/.local/bin/herdr"

if [ -n "$HERDR_BIN" ] && "$HERDR_BIN" server reload-agent-manifests >/dev/null 2>&1; then
    echo "reloaded: Herdr agent manifests"
else
    echo "note: Herdr server not running or reload unavailable — manifest loads on next server start"
fi
