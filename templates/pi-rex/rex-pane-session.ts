// Managed by dotfiles: templates/pi-rex/rex-pane-session.ts. Install: ./dot rex install --apply
// Records which pi session is open in which Rex pane, so `rex-safe-upgrade`
// can resume every agent after a Rex server restart.
// Writes ~/.local/state/rex-safe-upgrade/panes/<REX_BLOCK>.json on session start
// and on /new, /resume and /fork. No-op outside Rex.
// @ts-nocheck

import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const block = process.env.REX_BLOCK;
const dir = join(homedir(), ".local/state/rex-safe-upgrade/panes");

export default function (pi) {
  if (!block || !/^block:[0-9a-f-]+$/.test(block)) return;

  pi.on("session_start", async (event, ctx) => {
    const record = {
      kind: "pi",
      block,
      session: process.env.REX_SESSION ?? null,
      pid: process.pid,
      cwd: ctx.cwd,
      agentDir: process.env.PI_CODING_AGENT_DIR ?? null,
      sessionFile: ctx.sessionManager.getSessionFile() ?? null,
      sessionId: ctx.sessionManager.getSessionId() ?? null,
      reason: event.reason ?? null,
      updatedAt: new Date().toISOString(),
    };
    try {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      const file = join(dir, `${block.slice("block:".length)}.json`);
      const tmp = `${file}.${process.pid}.tmp`;
      writeFileSync(tmp, JSON.stringify(record, null, 2), { mode: 0o600 });
      renameSync(tmp, file);
    } catch {
      // Best effort: rex-safe-upgrade falls back to transcript matching.
    }
  });
}
