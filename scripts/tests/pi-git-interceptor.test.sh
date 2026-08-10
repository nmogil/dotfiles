#!/usr/bin/env bash
# Behavior test for Git safety compatibility with pi-auto-permissions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/scripts/lib/local-env.sh"
load_local_env || true
SCAFFOLD="${DOTFILES_PI_SCAFFOLD_DIR:-$ROOT/templates/pi}"
if [ ! -f "$SCAFFOLD/agent/extensions/git-interceptor.ts" ]; then
  printf '%s\n' 'skip Pi Git interceptor test (no scaffold source; set DOTFILES_PI_SCAFFOLD_DIR)'
  exit 0
fi
node --experimental-strip-types - \
  "$SCAFFOLD/agent/extensions/git-interceptor.ts" \
  "$SCAFFOLD/agent/pi-auto-permissions/config.json" <<'NODE'
const fs = require("node:fs");
const { pathToFileURL } = require("node:url");
const path = process.argv[2];
const permissionsConfigPath = process.argv[3];
const handlers = new Map();
const pi = {
  on(name, handler) {
    handlers.set(name, handler);
  },
};

(async () => {
  const extension = (await import(pathToFileURL(path).href)).default;
  extension(pi);

  if (process.env.GIT_EDITOR !== "true") throw new Error("GIT_EDITOR was not made non-interactive");
  if (process.env.GIT_SEQUENCE_EDITOR !== "true") throw new Error("GIT_SEQUENCE_EDITOR was not made non-interactive");
  if (process.env.GIT_MERGE_AUTOEDIT !== "no") throw new Error("GIT_MERGE_AUTOEDIT was not disabled");

  const handler = handlers.get("tool_call");
  if (!handler) throw new Error("tool_call handler was not registered");

  const exact = 'git commit --dry-run -m "smoke"';
  const allowed = { toolName: "bash", input: { command: exact } };
  const allowedResult = await handler(allowed);
  if (allowedResult !== undefined) throw new Error("ordinary Git command was blocked");
  if (allowed.input.command !== exact) throw new Error("Git command was rewritten before permission review");

  const bypass = { toolName: "bash", input: { command: "git commit --no-verify -m bad" } };
  const bypassResult = await handler(bypass);
  if (!bypassResult?.block) throw new Error("--no-verify was not blocked");
  for (const command of [
    "git commit -n -m bad",
    "git commit -nm bad",
    "git commit --no-veri -m bad",
    "git commit '-n' -m bad",
    "git commit \"-n\" -m bad",
    "git commit --no-'verify' -m bad",
  ]) {
    const shortBypass = { toolName: "bash", input: { command } };
    const shortBypassResult = await handler(shortBypass);
    if (!shortBypassResult?.block) throw new Error(`hook bypass was not blocked: ${command}`);
  }

  const permissions = JSON.parse(fs.readFileSync(permissionsConfigPath, "utf8"));
  const guarded = permissions.rules.map((rule) => new RegExp(rule.pattern, rule.flags));
  const commands = [
    "git commit -m smoke",
    "git -C repo commit -m smoke",
    "git -c user.name=bot push origin HEAD",
    "git " + "\\" + "\n" + "commit -m smoke",
    "npm publish",
    "npm --workspace pkg publish",
    "npm " + "\\" + "\n" + "publish",
  ];
  for (const command of commands) {
    if (!guarded.some((rule) => rule.test(command))) {
      throw new Error(`permission guard missed: ${command}`);
    }
  }
})();
NODE

printf '%s\n' 'ok   Git safety and guarded command variants remain permission-reviewed'
