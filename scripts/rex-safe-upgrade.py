#!/usr/bin/env python3
# Managed by dotfiles: scripts/rex-safe-upgrade.py. Install: ./dot rex install --apply
"""Restart the local Rex server onto the installed Rex version without losing work.

Rex keeps sessions, tabs, panes and scrollback across a server restart, but
every program running in a pane is stopped. This tool records which agent
conversation each pane is running, restarts the server, and resumes each agent
in its original pane.

  rex-safe-upgrade            show the plan (changes nothing)
  rex-safe-upgrade run        do it (detaches itself when run inside Rex)

Supported agents: pi (any PI_CODING_AGENT_DIR) and Hermes TUI. Idle shells need
nothing. Any other running program blocks the run unless --allow-unresumable.
pi panes are identified by the rex-pane-session pi extension.

Linux with systemd only. See docs/rex-safe-upgrade.md in the dotfiles repo.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path

HOME = Path.home()
STATE_ROOT = HOME / ".local/state/rex-safe-upgrade"
PANE_RECORDS = STATE_ROOT / "panes"
RUNS = STATE_ROOT / "runs"
REX_STATE = HOME / ".local/state/rex/servers"
SHELLS = {"zsh", "bash", "sh", "fish", "dash"}
KEEP_RUNS = 8
RECONNECT_WAIT = 90  # seconds to wait for the Rex app to relaunch the server


# ---------------------------------------------------------------- rex helpers

class RexError(Exception):
    pass


def rex(*args: str, check: bool = True, timeout: int = 30) -> str:
    cmd = ["rex", "--autostart=false", *args]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise RexError(f"{' '.join(args[:3])}: {p.stderr.strip() or p.stdout.strip()}")
    return p.stdout


def rex_json(*args: str) -> dict:
    return json.loads(rex(*args))


def block_call(session: str, block: str, method: str) -> dict:
    try:
        return json.loads(rex("block", "call", "-s", session, "-b", block, method))
    except (RexError, json.JSONDecodeError, subprocess.TimeoutExpired):
        return {}


def server_info() -> dict | None:
    try:
        return rex_json("whoami", "--json")
    except (RexError, json.JSONDecodeError, subprocess.TimeoutExpired):
        return None


def installed_version() -> str:
    out = subprocess.run(["rex", "version"], capture_output=True, text=True).stdout
    m = re.match(r"rex (\S+)", out)
    return m.group(1) if m else "?"


# ----------------------------------------------------------- process helpers

def proc_env(pid: int) -> dict[str, str]:
    try:
        raw = Path(f"/proc/{pid}/environ").read_bytes()
    except OSError:
        return {}
    env = {}
    for item in raw.split(b"\0"):
        k, sep, v = item.partition(b"=")
        if sep:
            env[k.decode(errors="replace")] = v.decode(errors="replace")
    return env


def proc_cmdline(pid: int) -> list[str]:
    try:
        return [a.decode(errors="replace") for a in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0") if a]
    except OSError:
        return []


def proc_start_epoch(pid: int) -> float:
    try:
        return Path(f"/proc/{pid}").stat().st_mtime
    except OSError:
        return 0.0


def proc_children(pid: int) -> list[int]:
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout
    return [int(x) for x in out.split()]


def descendants(pid: int) -> list[int]:
    todo, seen = [pid], []
    while todo:
        p = todo.pop()
        for c in proc_children(p):
            seen.append(c)
            todo.append(c)
    return seen


# ------------------------------------------------------------------ inventory

@dataclass
class Pane:
    session: str
    session_label: str
    window_label: str
    block: str
    fg_name: str
    fg_pid: int | None
    cwd: str
    state: str  # program_status state
    kind: str = "shell"  # shell | pi | hermes | unknown | empty
    resume_cmd: str | None = None
    source: str = ""  # how the resume target was found
    problem: str | None = None
    self_pane: bool = False

    @property
    def label(self) -> str:
        return f"{self.session_label} / {self.window_label}"


def pi_from_record(block: str, pid: int) -> dict | None:
    f = PANE_RECORDS / f"{block.removeprefix('block:')}.json"
    try:
        rec = json.loads(f.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if rec.get("pid") != pid:
        return None
    if not rec.get("sessionFile") or not Path(rec["sessionFile"]).is_file():
        rec["sessionFile"] = None  # empty or --no-session: nothing to resume, reopen fresh pi
    return rec


def hermes_resume_id(pid: int, cwd: str) -> tuple[str | None, str]:
    for c in descendants(pid):
        rid = proc_env(c).get("HERMES_TUI_RESUME")
        if rid:
            return rid, "HERMES_TUI_RESUME"
    argv = proc_cmdline(pid)
    if "--resume" in argv:
        i = argv.index("--resume")
        if i + 1 < len(argv):
            return argv[i + 1], "--resume argument"
    db = HOME / ".hermes/state.db"
    if db.exists():
        start = proc_start_epoch(pid)
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        row = con.execute(
            "select id from sessions where source='tui' and parent_session_id is null and cwd=? "
            "and started_at >= ? order by last_activity_at desc limit 1", (cwd, start - 5)).fetchone()
        con.close()
        if row:
            return row[0], "state.db (newest TUI session since start)"
    return None, "could not determine the Hermes session"


def is_hermes(pid: int) -> bool:
    argv = proc_cmdline(pid)
    joined = " ".join(argv)
    return "--tui" in argv and ("hermes" in joined)


def inventory(self_block: str | None) -> list[Pane]:
    panes: list[Pane] = []
    for s in rex_json("ls", "--json").get("sessions", []):
        sid, slabel = s["session_id"], s.get("label", "")
        insp = rex_json("session", "inspect", sid, "--json")
        wlabels = {}
        for w in insp.get("windows", []) or []:
            wlabels[w.get("window_id")] = w.get("label") or w.get("window_id", "")[-8:]
        for b in rex_json("block", "ls", "-s", sid, "--json").get("blocks", []):
            bid = b["block_id"]
            if not b.get("flavor", "").startswith("com.superlogical.terminal"):
                continue
            proc = block_call(sid, bid, "process")
            fg = proc.get("foreground") or proc.get("child") or {}
            ps = block_call(sid, bid, "program_status")
            recs = ps.get("records") or []
            pane = Pane(
                session=sid, session_label=slabel,
                window_label=wlabels.get(b.get("window_id"), b.get("window_id", "")[-8:]),
                block=bid, fg_name=fg.get("name", "-"), fg_pid=fg.get("pid"),
                cwd=fg.get("cwd") or proc.get("home") or str(HOME),
                state=recs[0].get("state", "-") if recs else "-",
                self_pane=(bid == self_block),
            )
            classify(pane)
            panes.append(pane)
    return panes


def classify(p: Pane) -> None:
    if p.fg_pid is None:
        p.kind = "empty"
        return
    if p.fg_name in SHELLS:
        p.kind = "shell"
        return
    argv0 = ((proc_cmdline(p.fg_pid) or [""])[0].split() or [""])[0]
    if p.fg_name == "node" and argv0.split("/")[-1] == "pi":
        p.kind = "pi"
        env = proc_env(p.fg_pid)
        rec = pi_from_record(p.block, p.fg_pid)
        if rec:
            agent_dir, sfile, p.source = rec.get("agentDir"), rec["sessionFile"], "pane record"
            agent_dir = agent_dir or env.get("PI_CODING_AGENT_DIR")
            if not sfile:
                p.source = "pane record (empty session, reopens fresh pi)"
        else:
            p.problem = "pi session not recorded (pi started before the recorder); type /reload in that pane"
            return
        prefix = ""
        if agent_dir and Path(agent_dir).resolve() != (HOME / ".pi/agent").resolve():
            prefix = f"PI_CODING_AGENT_DIR={shlex.quote(agent_dir)} "
        target = f" --session {shlex.quote(sfile)}" if sfile else ""
        p.resume_cmd = f"cd -- {shlex.quote(p.cwd)} && {prefix}pi{target}"
        return
    if p.fg_name.startswith("python") and is_hermes(p.fg_pid):
        p.kind = "hermes"
        rid, p.source = hermes_resume_id(p.fg_pid, p.cwd)
        if not rid:
            p.problem = p.source
            return
        p.resume_cmd = f"cd -- {shlex.quote(p.cwd)} && hermes --tui --resume {shlex.quote(rid)}"
        return
    p.kind = "unknown"
    p.problem = f"'{p.fg_name}' is running and can't be resumed automatically"


def blockers(panes: list[Pane], allow_unresumable: bool) -> list[str]:
    out = []
    for p in panes:
        if p.state == "working" and not p.self_pane:
            out.append(f"{p.label}: {p.kind} is mid-task")
        if p.problem and not allow_unresumable:
            out.append(f"{p.label}: {p.problem}")
    return out


def print_plan(panes: list[Pane], running: str, installed: str) -> None:
    print(f"running server: {running}\ninstalled rex:  {installed}"
          + ("   (up to date)" if running == installed else "   (restart needed)"))
    print()
    w = max((len(p.label) for p in panes), default=10)
    for p in panes:
        tag = " (this pane)" if p.self_pane else ""
        what = p.resume_cmd and f"resume via {p.source}" or p.problem or ("nothing to resume" if p.kind in ("shell", "empty") else "")
        print(f"  {p.label:<{w}}  {p.kind:<7} {p.state:<8} {what}{tag}")


# ------------------------------------------------------------------- the run

class Run:
    def __init__(self, run_dir: Path):
        self.dir = run_dir
        self.dir.mkdir(parents=True, exist_ok=True)
        self.logf = (self.dir / "log.txt").open("a")

    def log(self, msg: str) -> None:
        line = f"{dt.datetime.now().astimezone().isoformat(timespec='seconds')} {msg}"
        print(line, flush=True)
        self.logf.write(line + "\n")
        self.logf.flush()


def wait_for(pred, timeout: float, step: float = 1.0) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(step)
    return pred()


def do_run(args) -> int:
    run_dir = Path(args.run_dir) if args.run_dir else RUNS / dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    r = Run(run_dir)
    info = server_info()
    if not info:
        r.log("ABORT: no Rex server is running")
        return 1
    running, installed = info.get("rex_version", "?"), installed_version()
    r.log(f"running {running}, installed {installed}, server pid {info.get('pid')}")
    if running == installed and not args.even_if_current:
        r.log("server already runs the installed version; nothing to do")
        return 0

    # Wait for agents to go idle, then plan.
    deadline = time.time() + args.wait_idle * 60
    while True:
        panes = inventory(args.self_block)
        problems = blockers(panes, args.allow_unresumable)
        if not problems or time.time() >= deadline:
            break
        r.log(f"waiting for: {'; '.join(problems)}")
        time.sleep(30)
    (r.dir / "plan.json").write_text(json.dumps([asdict(p) for p in panes], indent=2))
    for p in panes:
        try:
            (r.dir / f"{p.block.removeprefix('block:')}.screen.txt").write_text(
                rex("capture", "-s", p.session, "-b", p.block, "--trim", "--unwrap", timeout=60))
        except (RexError, subprocess.TimeoutExpired):
            pass
    if problems:
        r.log("ABORT, nothing changed: " + "; ".join(problems))
        return 2
    if args.dry_run:
        r.log("dry run: preflight ok")
        return 0

    old_pid = info["pid"]
    endpoint = info.get("endpoint", "")
    r.log(f"stopping server pid {old_pid}")
    subprocess.run(["rex", "--autostart=false", "server", "stop"], capture_output=True, text=True, timeout=120)
    if not wait_for(lambda: not Path(f"/proc/{old_pid}").exists(), 90):
        r.log("ABORT: old server still running after 90s")
        return 3
    r.log("old server stopped (sessions saved)")
    sdir = REX_STATE / hashlib.sha256(endpoint.encode()).hexdigest()
    if sdir.is_dir():
        shutil.copytree(sdir, r.dir / "rex-state-backup")
        r.log(f"backed up saved sessions from {sdir}")

    if not wait_for(lambda: server_info() is not None, RECONNECT_WAIT):
        r.log(f"no reconnect from the Rex app in {RECONNECT_WAIT}s; starting the server here")
        subprocess.run(["rex", "server", "start"], capture_output=True, text=True, timeout=60)
    if not wait_for(lambda: server_info() is not None, 30):
        r.log(f"FAIL: server did not come back. Resume commands are in {r.dir}/plan.json")
        return 4
    new = server_info()
    r.log(f"server back: {new.get('rex_version')} pid {new.get('pid')}, {new.get('session_count')} sessions")

    results = []
    for p in panes:
        if not p.resume_cmd:
            continue
        ok = wait_for(lambda: block_call(p.session, p.block, "process").get("foreground", {}).get("name") in SHELLS, 60)
        if not ok:
            r.log(f"SKIP {p.label}: restored pane has no shell. Run manually: {p.resume_cmd}")
            results.append((p, False))
            continue
        time.sleep(2)  # let the shell prompt finish drawing
        try:
            rex("send", "-s", p.session, "-b", p.block, p.resume_cmd)
            rex("send-key", "-s", p.session, "-b", p.block, "enter")
            r.log(f"resumed {p.label}")
            results.append((p, True))
        except RexError as e:
            r.log(f"FAIL {p.label}: {e}. Run manually: {p.resume_cmd}")
            results.append((p, False))

    bad = 0
    for p, sent in results:
        if not sent:
            bad += 1
            continue
        expect = "pi" if p.kind == "pi" else "hermes"
        ok = wait_for(lambda: (block_call(p.session, p.block, "program_status").get("records") or [{}])[0].get("app") == expect, 60, 2)
        r.log(f"verify {p.label}: {'ok' if ok else 'NOT RUNNING. Run manually: ' + p.resume_cmd}")
        bad += 0 if ok else 1
    r.log(f"done: {len(results) - bad}/{len(results)} agents resumed")
    prune_runs()
    return 0 if bad == 0 else 5


def prune_runs() -> None:
    runs = sorted(RUNS.glob("*"))
    for old in runs[:-KEEP_RUNS]:
        shutil.rmtree(old, ignore_errors=True)


def inside_rex_server(server_pid: int | None) -> bool:
    """True if this process descends from the Rex server, so stopping it would kill us."""
    if not server_pid:
        return False
    pid = os.getpid()
    while pid > 1:
        if pid == server_pid:
            return True
        try:
            pid = int(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            return False
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", nargs="?", default="plan", choices=["plan", "run"])
    ap.add_argument("--dry-run", action="store_true", help="with run: preflight only")
    ap.add_argument("--wait-idle", type=float, default=0, metavar="MIN",
                    help="wait up to MIN minutes for busy agents to go idle (default: don't wait)")
    ap.add_argument("--allow-unresumable", action="store_true",
                    help="restart even if some panes run programs that can't be resumed")
    ap.add_argument("--even-if-current", action="store_true", help="restart even if already up to date")
    ap.add_argument("--self-block", default=os.environ.get("REX_BLOCK"), help=argparse.SUPPRESS)
    ap.add_argument("--run-dir", help=argparse.SUPPRESS)
    ap.add_argument("--detached", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()

    info = server_info()
    if not info:
        print("No Rex server is running; nothing to restart.")
        return 1
    running, installed = info.get("rex_version", "?"), installed_version()

    if args.command == "plan":
        panes = inventory(args.self_block)
        print_plan(panes, running, installed)
        problems = blockers(panes, args.allow_unresumable)
        print()
        if running == installed and not args.even_if_current:
            print("Nothing to do.")
        elif problems:
            print("Not safe right now:\n  " + "\n  ".join(problems))
        else:
            print("Safe to run:  rex-safe-upgrade run")
        return 0

    if not args.detached and inside_rex_server(info.get("pid")):
        if running == installed and not args.even_if_current:
            print(f"Server already runs {installed}; nothing to do.")
            return 0
        panes = inventory(args.self_block)
        problems = blockers(panes, args.allow_unresumable)
        if problems:
            print("Not safe right now, nothing changed:\n  " + "\n  ".join(problems))
            if not args.wait_idle:
                return 2
        if args.dry_run:
            print("Dry run: preflight ok.")
            return 0
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        run_dir = RUNS / stamp
        cmd = ["systemd-run", f"--unit=rex-safe-upgrade-{stamp}", "--collect", "-p", "Type=exec",
               f"--setenv=HOME={HOME}", f"--setenv=XDG_RUNTIME_DIR={os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')}",
               f"--setenv=PATH={os.environ.get('PATH', '/usr/bin:/bin')}",
               sys.executable, os.path.abspath(__file__), "run", "--detached", f"--run-dir={run_dir}",
               f"--wait-idle={args.wait_idle}"]
        if args.self_block:
            cmd.append(f"--self-block={args.self_block}")
        if args.allow_unresumable:
            cmd.append("--allow-unresumable")
        if args.even_if_current:
            cmd.append("--even-if-current")
        subprocess.run(cmd, check=True)
        print(f"Started rex-safe-upgrade-{stamp}. This pane will close and come back resumed.")
        print(f"Log: {run_dir}/log.txt")
        return 0

    return do_run(args)


if __name__ == "__main__":
    sys.exit(main())
