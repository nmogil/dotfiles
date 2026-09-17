// Original, credential-free Pi extension; canonical source in dotfiles.
// Early UX check only: real Git hooks validate effective per-command identity.
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

export function preflight(cwd: string): string | undefined {
  const guard = join(homedir(), ".local/share/git-identity-guard/guard.py");
  if (!existsSync(guard)) return undefined; // Explicitly opt-in installation.
  const result = spawnSync("python3", [guard, "check"], {
    cwd, encoding: "utf8", timeout: 5000,
  });
  if (result.error || result.status !== 0) {
    return result.stderr?.trim() || "Git identity preflight failed; inspect the local guard before committing.";
  }
  return undefined;
}

export default function (pi: any) {
  pi.registerCommand("git-identity", {
    description: "Check configured Git identity and hook routing (not Vercel membership)",
    handler: async (_args: string, ctx: any) => {
      const failure = preflight(ctx.cwd);
      ctx.ui.notify(failure || "Git identity preflight passed (or repo not opted in).", failure ? "error" : "info");
    },
  });
  pi.on("tool_call", (event: any, ctx: any) => {
    if (event.toolName !== "bash") return;
    const command = String(event.input.command ?? "");
    if (!/\bgit\b/.test(command) || !/\b(commit|push|merge|cherry-pick|rebase|am)\b/.test(command)) return;
    // Don't attempt to parse arbitrary shell. Hook-side checking covers cwd,
    // git -C, inline environment variables, -c user.email, and --author.
    const failure = preflight(ctx.cwd);
    if (failure) return { block: true, reason: failure };
  });
}
