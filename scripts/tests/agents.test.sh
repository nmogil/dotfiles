#!/usr/bin/env bash
# Integration tests for the read-only agent capability control surface.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.agents/skills/goal-contract" \
  "$TMP/.pi/agent/extensions" "$TMP/.claude" "$TMP/.codex" "$TMP/.hermes"
printf '%s\n' '# fixture' > "$TMP/.agents/skills/goal-contract/SKILL.md"
printf '%s\n' 'export default {}' > "$TMP/.pi/agent/extensions/git-interceptor.ts"
cat > "$TMP/.pi/agent/mcp.json" <<'JSON'
{
  "mcpServers": {
    "fixture-search": {
      "url": "https://secret.invalid/mcp",
      "headers": {"Authorization": "Bearer must-not-leak"}
    }
  }
}
JSON
cat > "$TMP/.claude/settings.json" <<'JSON'
{
  "enabledPlugins": {
    "vercel@claude-plugins-official": true,
    "disabled@example": false
  }
}
JSON
mkdir -p "$TMP/.claude/plugins/cache/claude-plugins-official/vercel/1.0.0"
cat > "$TMP/.claude/plugins/cache/claude-plugins-official/vercel/1.0.0/.mcp.json" <<'JSON'
{
  "plugin-vercel": {
    "url": "https://plugin-secret.invalid",
    "headers": {"Authorization": "must-not-leak-plugin-secret"}
  }
}
JSON
mkdir -p "$TMP/.claude/plugins/cache/claude-plugins-official/vercel/0.9.0"
printf '%s\n' '{"stale-server": {}}' \
  > "$TMP/.claude/plugins/cache/claude-plugins-official/vercel/0.9.0/.mcp.json"
cat > "$TMP/.claude/plugins/installed_plugins.json" <<'JSON'
{
  "version": 2,
  "plugins": {
    "vercel@claude-plugins-official": [
      {"scope": "user", "version": "1.0.0"}
    ]
  }
}
JSON

HOME="$TMP" "$ROOT/dot" agents inventory > "$TMP/inventory"
grep -q '^skills.shared: goal-contract$' "$TMP/inventory"
grep -q '^plugins.pi: git-interceptor$' "$TMP/inventory"
grep -q '^plugins.claude: vercel@claude-plugins-official$' "$TMP/inventory"
grep -q '^mcp.pi-personal: fixture-search$' "$TMP/inventory"
grep -q '^mcp.claude-plugin: plugin-vercel$' "$TMP/inventory"
! grep -q 'stale-server\|must-not-leak\|secret.invalid' "$TMP/inventory"

printf '%s\n' 'ok   agent inventory reports capability names without secret values'

mkdir -p "$TMP/.pi/agent/skills/pi-only" "$TMP/.pi/agent-work" \
  "$TMP/.claude/skills/claude-only" "$TMP/.codex/skills/codex-only" \
  "$TMP/.hermes/skills/hermes-only"
printf '%s\n' '{"mcpServers":{"work-only":{"url":"https://work-secret.invalid"}}}' \
  > "$TMP/.pi/agent-work/mcp.json"
cat > "$TMP/.claude.json" <<'JSON'
{
  "projects": {
    "/private/project/path": {
      "mcpServers": {
        "project-search": {"env": {"TOKEN": "project-secret"}}
      }
    }
  }
}
JSON
cat > "$TMP/.codex/config.toml" <<'TOML'
[mcp_servers.codex-search]
command = "secret-command"
TOML
cat > "$TMP/.hermes/config.yaml" <<'YAML'
mcp_servers:
  hermes-search:
    url: https://hermes-secret.invalid
plugins:
  disabled: []
  enabled:
    - herdr-agent-state
YAML

HOME="$TMP" DOTFILES_PI_WORK_PROFILE_SLUG=work \
  "$ROOT/dot" agents inventory > "$TMP/inventory-all"
for expected in \
  'skills.pi: pi-only' \
  'skills.claude: claude-only' \
  'skills.codex: codex-only' \
  'skills.hermes: hermes-only' \
  'plugins.hermes: herdr-agent-state' \
  'mcp.pi-work: work-only' \
  'mcp.claude: project-search' \
  'mcp.codex: codex-search' \
  'mcp.hermes: hermes-search'
do
  grep -q "^${expected}$" "$TMP/inventory-all"
done
! grep -q 'private/project\|secret-command\|secret.invalid\|project-secret' "$TMP/inventory-all"

printf '%s\n' 'ok   inventory covers each agent and profile without exposing locations or values'

POLICY="$TMP/policy"
mkdir -p "$POLICY" "$TMP/.agents/skills/unclassified-skill" \
  "$TMP/.pi/agent/skills/goal-contract" "$TMP/.pi/agent/skills/prototype" \
  "$TMP/.pi/agent/skills/shared-variant" "$TMP/.claude/skills/shared-variant"
printf '%s\n' '# divergent fixture' > "$TMP/.pi/agent/skills/goal-contract/SKILL.md"
printf '%s\n' '# Pi variant' > "$TMP/.pi/agent/skills/shared-variant/SKILL.md"
printf '%s\n' '# Claude variant' > "$TMP/.claude/skills/shared-variant/SKILL.md"
cat > "$POLICY/skills.json" <<'JSON'
{
  "version": 1,
  "enforceAssignments": false,
  "agents": {
    "pi": {
      "shared": ["goal-contract", "coding-standards", "shared-variant"],
      "local": ["local-keeper"],
      "review": ["prototype"]
    },
    "claude": {"shared": ["shared-variant"], "local": [], "review": []},
    "codex": {"shared": [], "local": [], "review": []},
    "hermes": {"shared": [], "local": [], "review": []}
  }
}
JSON
cat > "$POLICY/plugins.json" <<'JSON'
{
  "version": 1,
  "enforceAssignments": false,
  "agents": {
    "pi": {"keep": [], "review": []},
    "claude": {"keep": [], "review": []},
    "codex": {"keep": [], "review": []},
    "hermes": {"keep": [], "review": []}
  }
}
JSON
printf '%s\n' '{"version":1,"shareCredentials":false}' \
  > "$POLICY/mcp-policy.example.json"

HOME="$TMP" DOTFILES_AGENT_POLICY_DIR="$POLICY" \
  "$ROOT/dot" agents plan > "$TMP/plan"
grep -q '^canonical missing: coding-standards,shared-variant$' "$TMP/plan"
grep -q '^canonical unclassified: unclassified-skill$' "$TMP/plan"
grep -q '^shared variants differ: shared-variant (claude,pi)$' "$TMP/plan"
grep -q '^pi divergent shared copy: goal-contract$' "$TMP/plan"
grep -q '^pi assigned shared missing: coding-standards$' "$TMP/plan"
grep -q '^pi local keep missing: local-keeper$' "$TMP/plan"
grep -q '^pi review installed: prototype$' "$TMP/plan"
grep -q '^pi unclassified installed: pi-only$' "$TMP/plan"
grep -q '^assignment enforcement: disabled (report only)$' "$TMP/plan"

printf '%s\n' 'ok   agent plan reports canonical, assignment, divergence, and review drift'

HOME="$TMP" DOTFILES_AGENT_POLICY_DIR="$POLICY" \
  "$ROOT/dot" agents check > "$TMP/check"
grep -q '^ok   skills policy$' "$TMP/check"
grep -q '^ok   plugins policy$' "$TMP/check"
grep -q '^ok   MCP credentials are declared non-shareable$' "$TMP/check"
grep -q '^WARN assignment enforcement disabled; drift is report-only$' "$TMP/check"

printf '%s\n' 'ok   agent check validates policy while assignments remain report-only'

BAD_POLICY="$TMP/bad-policy"
mkdir -p "$BAD_POLICY"
cat > "$BAD_POLICY/skills.json" <<'JSON'
{
  "version": 1,
  "enforceAssignments": false,
  "agents": {
    "pi": {
      "shared": ["goal-contract", "must-not-leak secret"],
      "local": [],
      "review": ["goal-contract"]
    },
    "claude": {"shared": [], "local": [], "review": []},
    "codex": {"shared": [], "local": [], "review": []},
    "hermes": {"shared": [], "local": [], "review": []}
  }
}
JSON
printf '%s\n' '{"version":1,"enforceAssignments":false,"agents":{"rogue":{}}}' \
  > "$BAD_POLICY/plugins.json"
printf '%s\n' '{"version":1,"shareCredentials":true}' \
  > "$BAD_POLICY/mcp-policy.example.json"

if HOME="$TMP" DOTFILES_AGENT_POLICY_DIR="$BAD_POLICY" \
  "$ROOT/dot" agents check > "$TMP/bad-check"; then
  echo 'FAIL invalid policy unexpectedly passed' >&2
  exit 1
fi
grep -q '^FAIL skills policy:' "$TMP/bad-check"
grep -q '^FAIL plugins policy:' "$TMP/bad-check"
grep -q '^FAIL MCP policy must prohibit credential sharing$' "$TMP/bad-check"
! grep -q 'must-not-leak' "$TMP/bad-check"

printf '%s\n' 'ok   agent check rejects unsafe, overlapping, and credential-sharing policy'

printf '%s\n' 'export default {}' > "$TMP/.pi/agent/extensions/pi-memory-compiler.ts"
cat > "$TMP/.claude/settings.json" <<'JSON'
{
  "enabledPlugins": {
    "vercel@claude-plugins-official": true,
    "superpowers@claude-plugins-official": true,
    "unclassified@example": true
  }
}
JSON
cat > "$TMP/.hermes/config.yaml" <<'YAML'
mcp_servers: {}
plugins:
  disabled: []
  enabled:
    - herdr-agent-state
    - spotify
YAML
cat > "$POLICY/plugins.json" <<'JSON'
{
  "version": 1,
  "enforceAssignments": false,
  "agents": {
    "pi": {
      "keep": ["git-interceptor", "account-profile-indicator"],
      "review": ["pi-memory-compiler"]
    },
    "claude": {
      "keep": ["vercel@claude-plugins-official"],
      "review": ["superpowers@claude-plugins-official"]
    },
    "codex": {"keep": [], "review": []},
    "hermes": {"keep": ["herdr-agent-state"], "review": ["spotify"]}
  }
}
JSON

HOME="$TMP" DOTFILES_AGENT_POLICY_DIR="$POLICY" \
  "$ROOT/dot" agents plan > "$TMP/plugin-plan"
grep -q '^pi plugin keep missing: account-profile-indicator$' "$TMP/plugin-plan"
grep -q '^pi plugin review enabled: pi-memory-compiler$' "$TMP/plugin-plan"
grep -q '^claude plugin review enabled: superpowers@claude-plugins-official$' "$TMP/plugin-plan"
grep -q '^claude plugin unclassified enabled: unclassified@example$' "$TMP/plugin-plan"
grep -q '^hermes plugin review enabled: spotify$' "$TMP/plugin-plan"

printf '%s\n' 'ok   agent plan reports missing keepers and enabled review plugins'

mkdir -p "$TMP/.config/dotfiles" "$TMP/.pi/agent-clientx"
printf '%s\n' 'DOTFILES_PI_WORK_PROFILE_SLUG="clientx"' \
  > "$TMP/.config/dotfiles/local.env"
printf '%s\n' '{"mcpServers":{"client-work-search":{}}}' \
  > "$TMP/.pi/agent-clientx/mcp.json"
HOME="$TMP" "$ROOT/dot" agents inventory > "$TMP/local-profile-inventory"
grep -q '^mcp.pi-work: client-work-search$' "$TMP/local-profile-inventory"

printf '%s\n' 'ok   inventory honors the locally configured Pi work profile'

agent_state_digest() {
  find "$TMP/.agents" "$TMP/.pi" "$TMP/.claude" "$TMP/.codex" "$TMP/.hermes" \
    -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    | sha256sum \
    | cut -d' ' -f1
}
before="$(agent_state_digest)"
HOME="$TMP" DOTFILES_AGENT_POLICY_DIR="$POLICY" "$ROOT/dot" agents inventory >/dev/null
HOME="$TMP" DOTFILES_AGENT_POLICY_DIR="$POLICY" "$ROOT/dot" agents plan >/dev/null
HOME="$TMP" DOTFILES_AGENT_POLICY_DIR="$POLICY" "$ROOT/dot" agents check >/dev/null
after="$(agent_state_digest)"
test "$before" = "$after"

printf '%s\n' 'ok   inventory, plan, and check do not mutate agent state'

TRAVERSAL_POLICY="$TMP/traversal-policy"
mkdir -p "$TRAVERSAL_POLICY"
cat > "$TRAVERSAL_POLICY/skills.json" <<'JSON'
{
  "version": 1,
  "enforceAssignments": false,
  "agents": {
    "pi": {"shared": ["a/../../must-not-leak"], "local": [], "review": []},
    "claude": {"shared": [], "local": [], "review": []},
    "codex": {"shared": [], "local": [], "review": []},
    "hermes": {"shared": [], "local": [], "review": []}
  }
}
JSON
cp "$POLICY/plugins.json" "$TRAVERSAL_POLICY/plugins.json"
cp "$POLICY/mcp-policy.example.json" "$TRAVERSAL_POLICY/mcp-policy.example.json"
if HOME="$TMP" DOTFILES_AGENT_POLICY_DIR="$TRAVERSAL_POLICY" \
  "$ROOT/dot" agents check > "$TMP/traversal-check"; then
  echo 'FAIL path-like capability name unexpectedly passed' >&2
  exit 1
fi
grep -q '^FAIL skills policy: pi.shared must contain safe capability names$' \
  "$TMP/traversal-check"
! grep -q 'must-not-leak' "$TMP/traversal-check"
if HOME="$TMP" DOTFILES_AGENT_POLICY_DIR="$TRAVERSAL_POLICY" \
  "$ROOT/dot" agents plan > "$TMP/traversal-plan" 2>&1; then
  echo 'FAIL plan accepted a path-like capability name' >&2
  exit 1
fi
grep -q '^manage-agents: invalid skills policy$' "$TMP/traversal-plan"
! grep -q 'must-not-leak' "$TMP/traversal-plan"

printf '%s\n' 'ok   policy rejects path-like capability names without echoing them'

HOME="$TMP" PI_CODING_AGENT_DIR="$TMP/.pi/agent-clientx" \
  "$ROOT/dot" agents inventory > "$TMP/work-context-inventory"
grep -q '^mcp.pi-personal: fixture-search$' "$TMP/work-context-inventory"
grep -q '^mcp.pi-work: client-work-search$' "$TMP/work-context-inventory"

printf '%s\n' 'ok   inventory keeps personal/work labels stable inside a work-profile process'

ENFORCED_POLICY="$TMP/enforced-policy"
cp -R "$POLICY" "$ENFORCED_POLICY"
python3 - "$ENFORCED_POLICY" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
for name in ("skills.json", "plugins.json"):
    path = root / name
    policy = json.loads(path.read_text())
    policy["enforceAssignments"] = True
    path.write_text(json.dumps(policy))
PY
if HOME="$TMP" DOTFILES_AGENT_POLICY_DIR="$ENFORCED_POLICY" \
  "$ROOT/dot" agents check > "$TMP/enforced-check"; then
  echo 'FAIL unimplemented assignment enforcement unexpectedly passed' >&2
  exit 1
fi
grep -q '^FAIL assignment enforcement is not available in the read-only phase$' \
  "$TMP/enforced-check"

printf '%s\n' 'ok   check cannot claim assignment enforcement before apply support exists'
