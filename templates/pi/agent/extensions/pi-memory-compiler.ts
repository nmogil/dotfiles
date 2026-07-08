import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

interface PiMemoryCompilerConfig {
  enabled?: boolean;
  compilerDir?: string;
  flushScript?: string;
  minSecondsBetweenFlushes?: number;
  notify?: boolean;
}

interface PiMemoryState {
  lastFlushBySession?: Record<string, number>;
}

const DEFAULT_CONFIG: Required<PiMemoryCompilerConfig> = {
  enabled: true,
  compilerDir: "/root/github_repos/personal/claude-memory-compiler",
  flushScript: "scripts/pi_session.py",
  minSecondsBetweenFlushes: 60,
  notify: false,
};

const AGENT_DIR = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");
const CONFIG_PATH = join(AGENT_DIR, "memory-compiler.json");
const STATE_PATH = join(AGENT_DIR, ".cache", "memory-compiler-state.json");

function expandHome(path: string): string {
  return path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}

function loadConfig(): Required<PiMemoryCompilerConfig> {
  if (!existsSync(CONFIG_PATH)) return DEFAULT_CONFIG;

  try {
    const parsed = JSON.parse(readFileSync(CONFIG_PATH, "utf8")) as PiMemoryCompilerConfig;
    return {
      ...DEFAULT_CONFIG,
      ...parsed,
      compilerDir: expandHome(parsed.compilerDir ?? DEFAULT_CONFIG.compilerDir),
      flushScript: parsed.flushScript ?? DEFAULT_CONFIG.flushScript,
    };
  } catch {
    return DEFAULT_CONFIG;
  }
}

function loadState(): PiMemoryState {
  if (!existsSync(STATE_PATH)) return {};
  try {
    return JSON.parse(readFileSync(STATE_PATH, "utf8")) as PiMemoryState;
  } catch {
    return {};
  }
}

function saveState(state: PiMemoryState) {
  mkdirSync(dirname(STATE_PATH), { recursive: true });
  writeFileSync(STATE_PATH, JSON.stringify(state, null, 2), "utf8");
}

function shouldFlush(sessionFile: string, config: Required<PiMemoryCompilerConfig>) {
  const now = Math.floor(Date.now() / 1000);
  const state = loadState();
  const lastBySession = state.lastFlushBySession ?? {};
  const last = lastBySession[sessionFile] ?? 0;
  if (now - last < config.minSecondsBetweenFlushes) return false;
  lastBySession[sessionFile] = now;
  saveState({ ...state, lastFlushBySession: lastBySession });
  return true;
}

function spawnPiFlush(sessionFile: string, config: Required<PiMemoryCompilerConfig>) {
  const compilerDir = expandHome(config.compilerDir);
  const scriptPath = join(compilerDir, config.flushScript);
  if (!existsSync(sessionFile) || !existsSync(scriptPath)) return false;
  if (!shouldFlush(sessionFile, config)) return false;

  const child = spawn(
    "uv",
    ["run", "--directory", compilerDir, "python", scriptPath, sessionFile],
    {
      cwd: compilerDir,
      detached: true,
      stdio: "ignore",
      env: {
        ...process.env,
        PI_MEMORY_COMPILER_SOURCE: "pi",
      },
    },
  );
  child.unref();
  return true;
}

export default function (pi: any) {
  const maybeFlush = async (ctx: any, reason: string) => {
    const config = loadConfig();
    if (!config.enabled) return;

    const sessionFile = ctx.sessionManager?.getSessionFile?.();
    if (!sessionFile || typeof sessionFile !== "string") return;

    const spawned = spawnPiFlush(sessionFile, config);
    if (spawned && config.notify && ctx.hasUI) {
      ctx.ui.notify(`Queued Pi memory capture: ${basename(sessionFile)} (${reason})`, "info");
    }
  };

  pi.on("session_compact", async (_event: any, ctx: any) => {
    await maybeFlush(ctx, "compact");
  });

  pi.on("session_shutdown", async (event: any, ctx: any) => {
    await maybeFlush(ctx, event?.reason ?? "shutdown");
  });
}
