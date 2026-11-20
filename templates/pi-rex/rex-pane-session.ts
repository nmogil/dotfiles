// Managed by dotfiles: templates/pi-rex/rex-pane-session.ts. Install: ./dot rex install --apply
// Records which pi session is open in which Rex pane, so `rex-safe-upgrade`
// can resume every agent after a Rex server restart.
// Writes ~/.local/state/rex-safe-upgrade/panes/<REX_BLOCK>.json when a session
// starts (including /new, /resume, /fork and /reload) and after each agent run.
// No-op outside Rex. See docs/rex-safe-upgrade.md.
// @ts-nocheck

import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const block = process.env.REX_BLOCK;
const dir = join(homedir(), ".local/state/rex-safe-upgrade/panes");
const file = block ? join(dir, `${block.slice("block:".length)}.json`) : "";

// Kernel start time of this process: with the pid, it identifies this exact
// process even if the pid is reused later.
function startTicks() {
  try {
    return readFileSync("/proc/self/stat", "utf8").split(")").pop().trim().split(" ")[19] ?? null;
  } catch {
    return null;
  }
}

export default function (pi) {
  if (!block || !/^block:[0-9a-f-]+$/.test(block)) return;

  // hasMessages: the agent has run at least once in this session, so its
  // session file must exist. A missing file then means it was lost, not empty.
  const write = (ctx, reason, hasMessages) => {
    const record = {
      v: 2,
      kind: "pi",
      block,
      session: process.env.REX_SESSION ?? null,
      pid: process.pid,
      startTicks: startTicks(),
      cwd: ctx.cwd,
      agentDir: process.env.PI_CODING_AGENT_DIR ?? null,
      sessionFile: ctx.sessionManager.getSessionFile() ?? null,
      sessionId: ctx.sessionManager.getSessionId() ?? null,
      hasMessages,
      reason,
      updatedAt: new Date().toISOString(),
    };
    try {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      const tmp = `${file}.${process.pid}.tmp`;
      writeFileSync(tmp, JSON.stringify(record, null, 2), { mode: 0o600 });
      renameSync(tmp, file);
    } catch {
      // Best effort. Without a current record, rex-safe-upgrade refuses to
      // restart and asks for /reload in this pane.
    }
  };

  pi.on("session_start", async (event, ctx) => {
    const hasMessages = ctx.sessionManager.getEntries().some((e) => e.type === "message" && e.message?.role === "user");
    write(ctx, event.reason ?? null, hasMessages);
  });
  pi.on("agent_end", async (_event, ctx) => write(ctx, "agent_end", true));
  // Before /new, /resume, /fork or /clone: drop this session's record first,
  // so if the next write fails there is no record rather than a wrong one.
  // If it can't be dropped, cancel the switch: otherwise rex-safe-upgrade
  // could later reopen the previous conversation in this pane.
  const invalidate = (ctx) => {
    try {
      rmSync(file, { force: true });
      return undefined;
    } catch (err) {
      ctx.ui.notify(
        `rex-pane-session: can't remove ${file} (${err?.code ?? err}); session switch cancelled. ` +
          "Fix that path, or remove this extension.",
        "error",
      );
      return { cancel: true };
    }
  };
  pi.on("session_before_switch", async (_event, ctx) => invalidate(ctx));
  pi.on("session_before_fork", async (_event, ctx) => invalidate(ctx));
  // On quit the process ends, so its pid can't match a later record check.
  pi.on("session_shutdown", async () => {
    try {
      rmSync(file, { force: true });
    } catch {
      // Best effort.
    }
  });
}
