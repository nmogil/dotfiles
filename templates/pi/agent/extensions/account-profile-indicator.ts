import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function getProfileLabel(): string {
  const defaultDir = join(homedir(), ".pi", "agent");
  const activeName = basename(resolve(process.env.PI_CODING_AGENT_DIR ?? defaultDir));

  if (activeName === "agent") return "PERSONAL";
  if (activeName.startsWith("agent-") && activeName.length > "agent-".length) {
    return activeName.slice("agent-".length).toUpperCase();
  }
  return `PROFILE:${activeName}`;
}

/** Displays the active Pi credential profile persistently in the footer. */
export default function accountProfileIndicator(pi: ExtensionAPI): void {
  pi.on("session_start", (_event, ctx) => {
    if (!ctx.hasUI) return;

    const label = getProfileLabel();
    const color = label === "PERSONAL" ? "accent" : "warning";
    const badge = ctx.ui.theme.fg(color, ctx.ui.theme.bold(`[${label}]`));
    ctx.ui.setStatus("account-profile", badge);
  });
}
