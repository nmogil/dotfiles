#!/usr/bin/env python3
# Managed by dotfiles: scripts/rex-safe-upgrade.py. Install: ./dot rex install --apply
"""Restart the local Rex server onto the installed Rex version without losing work.

Rex keeps sessions, tabs, panes and scrollback across a server restart, but
every program running in a pane is stopped. This tool works out which agent
conversation each pane has open, restarts the server, and resumes each agent
in its original pane.

  rex-safe-upgrade            show the plan (changes nothing)
  rex-safe-upgrade run        do it (detaches itself when run inside Rex)

Supported agents: pi (via the rex-pane-session pi extension) and Hermes TUI.
Idle shells need nothing. Anything it can't account for blocks the run.

Linux with systemd only. See docs/rex-safe-upgrade.md in the dotfiles repo.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path

HOME = Path.home()
STATE_ROOT = HOME / ".local/state/rex-safe-upgrade"
PANE_RECORDS = STATE_ROOT / "panes"
RUNS = STATE_ROOT / "runs"
LOCK = STATE_ROOT / "run.lock"
REX_STATE = HOME / ".local/state/rex/servers"
SHELLS = {"zsh", "bash", "sh", "fish", "dash"}
SHELL_HELPERS = ("gitstatusd",)  # prompt helpers that live under an idle shell
IDLE_STATES = {"idle", "done", "-"}
KEEP_RUNS = 8
# Seconds to wait for the Rex app to relaunch the server, and for each pane.
RECONNECT_WAIT = float(os.environ.get("REX_SAFE_UPGRADE_RECONNECT_WAIT", 90))
PANE_WAIT = float(os.environ.get("REX_SAFE_UPGRADE_PANE_WAIT", 60))
START_WAIT = float(os.environ.get("REX_SAFE_UPGRADE_START_WAIT", 30))


# ---------------------------------------------------------------- rex helpers

class RexError(Exception):
    pass


def rex(*args: str, timeout: int = 30) -> str:
    try:
        p = subprocess.run(["rex", "--autostart=false", *args], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        raise RexError(f"rex {' '.join(args[:3])}: timed out") from e
    except OSError as e:
        raise RexError(f"rex {' '.join(args[:3])}: {e}") from e
    if p.returncode != 0:
        raise RexError(f"rex {' '.join(args[:3])}: {p.stderr.strip() or p.stdout.strip()}")
    return p.stdout


def rex_json(*args: str) -> dict:
    try:
        return json.loads(rex(*args))
    except json.JSONDecodeError as e:
        raise RexError(f"rex {' '.join(args[:3])}: bad JSON") from e


def block_call(session: str, block: str, method: str) -> dict | None:
    """None when the call fails; callers decide whether that blocks."""
    try:
        return rex_json("block", "call", "-s", session, "-b", block, method)
    except RexError:
        return None


def server_info() -> dict | None:
    try:
        return rex_json("whoami", "--json")
    except RexError:
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


def proc_name(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/comm").read_text().strip()
    except OSError:
        return "?"


def proc_start_ticks(pid: int) -> str | None:
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def proc_parent(pid: int) -> int:
    try:
        return int(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        return 0


def proc_children(pid: int) -> list[int]:
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout
    return [int(x) for x in out.split()]


def descendants(pid: int) -> list[int]:
    todo, seen = [pid], []
    while todo:
        for c in proc_children(todo.pop()):
            seen.append(c)
            todo.append(c)
    return seen


def is_ancestor(ancestor: int, pid: int) -> bool:
    while pid > 1:
        if pid == ancestor:
            return True
        pid = proc_parent(pid)
    return False


# ------------------------------------------------------------------ inventory

@dataclass
class Pane:
    session: str
    session_label: str
    window_label: str
    block: str
    fg_name: str = "-"
    fg_pid: int | None = None
    fg_ticks: str | None = None  # start time: tells a reused pid apart
    cwd: str = ""
    state: str = "-"  # program_status state of the foreground program
    kind: str = "shell"  # shell | pi | hermes | unknown
    resume_cmd: str | None = None
    target: str | None = None  # session file or Hermes id being resumed
    source: str = ""  # how the target was found
    problem: str | None = None
    hard: bool = False  # problem can't be waived with --allow-unresumable
    self_pane: bool = False

    @property
    def label(self) -> str:
        return f"{self.session_label} / {self.window_label}"


def inventory(self_id: str | None) -> list[Pane]:
    """self_id is "<block>:<pid>:<start ticks>" of the agent that started the run."""
    panes: list[Pane] = []
    for s in rex_json("ls", "--json").get("sessions", []):
        sid, slabel = s["session_id"], s.get("label", "")
        insp = rex_json("session", "inspect", sid, "--json")
        wlabels = {w.get("window_id"): w.get("label") or w.get("window_id", "")[-8:]
                   for w in insp.get("windows") or []}
        for b in rex_json("block", "ls", "-s", sid, "--json").get("blocks", []):
            if not b.get("flavor", "").startswith("com.superlogical.terminal"):
                continue
            pane = Pane(session=sid, session_label=slabel, block=b["block_id"],
                        window_label=wlabels.get(b.get("window_id"), b.get("window_id", "")[-8:]))
            inspect_pane(pane)
            pane.self_pane = bool(pane.fg_pid) and self_id == pane_identity(pane.block, pane.fg_pid)
            panes.append(pane)
    flag_duplicates(panes)
    return panes


def pane_identity(block: str, pid: int) -> str:
    return f"{block}:{pid}:{proc_start_ticks(pid)}"


def inspect_pane(p: Pane) -> None:
    proc = block_call(p.session, p.block, "process")
    status = block_call(p.session, p.block, "program_status")
    if proc is None or status is None:
        p.kind, p.problem, p.hard = "unknown", "couldn't read the pane's state from Rex", True
        return
    fg = proc.get("foreground") or {}
    top = (proc.get("child") or {}).get("pid")
    if not fg.get("pid"):
        if top:
            p.kind, p.problem, p.hard = "unknown", "Rex reports no foreground program", True
        else:
            p.kind = "shell"  # pane has exited; nothing runs in it
        return
    p.fg_name, p.fg_pid = fg.get("name", "?"), fg["pid"]
    p.cwd = fg.get("cwd") or proc.get("home") or str(HOME)
    # Use the status only when it belongs to the program that runs now.
    p.fg_ticks = proc_start_ticks(p.fg_pid)
    # Only a status reported by the program running now says whether it's busy.
    owned = [r for r in status.get("records") or [] if (r.get("owner") or {}).get("pid") == p.fg_pid]
    p.state = owned[0].get("state", "-") if owned else "-"

    if top and proc_name(top) in SHELLS:  # jobs started from the pane's shell
        extra = [c for c in proc_children(top) if c != p.fg_pid and not proc_name(c).startswith(SHELL_HELPERS)]
        if extra:
            p.kind = "unknown"
            p.problem = "background processes would be stopped: " + ", ".join(sorted({proc_name(c) for c in extra}))
            return
    if p.fg_name in SHELLS:
        p.kind = "shell"
        return
    argv = proc_cmdline(p.fg_pid)
    argv0 = (argv[0].split() or [""])[0] if argv else ""
    if p.fg_name == "node" and argv0.rsplit("/", 1)[-1] == "pi":
        classify_pi(p)
    elif p.fg_name.startswith("python") and "--tui" in argv and "hermes" in " ".join(argv):
        classify_hermes(p, argv)
    else:
        p.kind = "unknown"
        p.problem = f"'{p.fg_name}' is running and can't be resumed automatically"
        return
    if not owned:  # an agent we can't see the state of might be mid-task
        p.problem = "; ".join(filter(None, [p.problem, f"{p.kind} hasn't reported whether it's busy"]))
        p.hard = True


def read_record(block: str) -> dict | None:
    try:
        return json.loads((PANE_RECORDS / f"{block.removeprefix('block:')}.json").read_text())
    except (OSError, json.JSONDecodeError):
        return None


def valid_record(rec: dict | None, pid: int, ticks: str | None) -> bool:
    """A current-format record written by exactly this pi process."""
    return bool(rec and rec.get("v") == 2 and rec.get("pid") == pid and ticks
                and rec.get("startTicks") == ticks and isinstance(rec.get("hasMessages"), bool))


def classify_pi(p: Pane) -> None:
    p.kind = "pi"
    rec = read_record(p.block)
    if not valid_record(rec, p.fg_pid, p.fg_ticks):
        p.problem = "pi hasn't recorded its session (started before the current recorder); type /reload in that pane"
        return
    sfile = rec.get("sessionFile")
    p.source = "pane record"
    if sfile and not Path(sfile).is_file():
        if rec.get("hasMessages"):
            p.problem = f"pi's recorded session file is missing: {sfile}"
            return
        sfile = None  # session has no messages yet, so pi hasn't written it
    if not sfile:
        p.source = "pane record (empty session, reopens fresh pi)"
    agent_dir = rec.get("agentDir")
    prefix = ""
    if agent_dir and Path(agent_dir).resolve() != (HOME / ".pi/agent").resolve():
        prefix = f"PI_CODING_AGENT_DIR={shlex.quote(agent_dir)} "
    p.target = sfile
    target = f" --session {shlex.quote(sfile)}" if sfile else ""
    p.resume_cmd = f"cd -- {shlex.quote(p.cwd)} && {prefix}pi{target}"


def hermes_session(pid: int, argv: list[str]) -> tuple[str | None, str]:
    procs = [pid, *descendants(pid)]
    # The TUI writes the live session id here whenever it starts or switches session.
    for c in procs:
        f = proc_env(c).get("HERMES_TUI_ACTIVE_SESSION_FILE")
        if f:
            try:
                sid = json.loads(Path(f).read_text()).get("session_id")
            except (OSError, json.JSONDecodeError, AttributeError):
                sid = None
            if sid:
                return sid, "active session file"
    for c in procs:
        rid = proc_env(c).get("HERMES_TUI_RESUME")
        if rid:
            return rid, "HERMES_TUI_RESUME"
    if "--resume" in argv[:-1]:
        return argv[argv.index("--resume") + 1], "--resume argument"
    return None, "couldn't tell which Hermes session is open"


def classify_hermes(p: Pane, argv: list[str]) -> None:
    p.kind = "hermes"
    rid, p.source = hermes_session(p.fg_pid, argv)
    if not rid:
        p.problem = p.source
        return
    p.target = rid
    p.resume_cmd = f"cd -- {shlex.quote(p.cwd)} && hermes --tui --resume {shlex.quote(rid)}"


def flag_duplicates(panes: list[Pane]) -> None:
    seen: dict[str, list[Pane]] = {}
    for p in panes:
        if p.target:
            seen.setdefault(p.target, []).append(p)
    for group in seen.values():
        if len(group) > 1:
            for p in group:
                p.hard = True
                p.problem = "same conversation open in another pane: " + ", ".join(o.label for o in group if o is not p)


def blockers(panes: list[Pane], allow_unresumable: bool) -> list[str]:
    out = []
    for p in panes:
        if p.state not in IDLE_STATES and not p.self_pane:
            out.append(f"{p.label}: {p.kind} is {p.state}")
        if p.problem and (p.hard or not allow_unresumable):
            out.append(f"{p.label}: {p.problem}")
    return out


def print_plan(panes: list[Pane], running: str, installed: str) -> None:
    print(f"running server: {running}\ninstalled rex:  {installed}"
          + ("   (up to date)" if running == installed else "   (restart needed)"))
    print()
    w = max((len(p.label) for p in panes), default=10)
    for p in panes:
        what = (p.resume_cmd and f"resume via {p.source}") or p.problem or "nothing to resume"
        print(f"  {p.label:<{w}}  {p.kind:<7} {p.state:<8} {what}{' (this pane)' if p.self_pane else ''}")


# ------------------------------------------------------------------- the run

class Run:
    def __init__(self, run_dir: Path):
        self.dir = run_dir
        self.dir.mkdir(parents=True, exist_ok=True, mode=0o700)
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
    return bool(pred())


def acquire_lock():
    STATE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    f = LOCK.open("w")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return None
    return f


def plan_key(panes: list[Pane]) -> dict:
    return {p.block: (p.kind, p.fg_pid, p.fg_ticks, p.resume_cmd, p.problem) for p in panes}


def new_run_name() -> str:
    return f"{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"


def do_run(args) -> int:
    lock = acquire_lock()
    if not lock:
        print("ABORT: another rex-safe-upgrade run is in progress; nothing changed", flush=True)
        return 6
    run_dir = Path(args.run_dir) if args.run_dir else RUNS / new_run_name()
    r = Run(run_dir)
    try:
        return run_locked(r, args)
    finally:
        prune_runs(keep=run_dir)


def run_locked(r: Run, args) -> int:
    info = server_info()
    if not info:
        r.log("ABORT: no Rex server is running")
        return 1
    running, installed = info.get("rex_version", "?"), installed_version()
    r.log(f"running {running}, installed {installed}, server pid {info.get('pid')}")
    if running == installed and not args.even_if_current:
        r.log("server already runs the installed version; nothing to do")
        return 0

    deadline = time.time() + args.wait_idle * 60
    while True:
        panes = inventory(args.self_id)
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
        except RexError:
            pass
    if problems:
        r.log("ABORT, nothing changed: " + "; ".join(problems))
        return 2
    if args.dry_run:
        r.log("dry run: preflight ok")
        return 0

    # Last look right before stopping: same server, same panes, still idle.
    now = server_info()
    if not now or (now.get("instance_id"), now.get("pid")) != (info.get("instance_id"), info.get("pid")):
        r.log("ABORT, nothing changed: the Rex server changed during preflight")
        return 3
    final = inventory(args.self_id)
    problems = blockers(final, args.allow_unresumable)
    if problems or plan_key(final) != plan_key(panes):
        r.log("ABORT, nothing changed: panes changed during preflight. " + "; ".join(problems))
        return 2

    return restart_and_resume(r, panes, info)


def restart_and_resume(r: Run, panes: list[Pane], info: dict) -> int:
    todo = [p for p in panes if p.resume_cmd]

    def manual(reason: str) -> None:
        r.log(reason)
        for p in todo:
            r.log(f"  to resume {p.label}, type in that pane: {p.resume_cmd}")

    old_pid = info["pid"]
    r.log(f"stopping server pid {old_pid}")
    try:
        subprocess.run(["rex", "--autostart=false", "server", "stop"], capture_output=True, text=True, timeout=120)
    except (subprocess.TimeoutExpired, OSError) as e:
        r.log(f"warning: rex server stop: {e}")  # outcome checked below
    if not wait_for(lambda: not Path(f"/proc/{old_pid}").exists(), 90):
        manual(f"FAIL: server pid {old_pid} still running 90s after stop. Pane programs may already "
               "have stopped: check each pane, and where an agent is gone, type:")
        return 3
    r.log("old server stopped (sessions saved)")

    try:
        sdir = REX_STATE / hashlib.sha256(info.get("endpoint", "").encode()).hexdigest()
        if sdir.is_dir():
            shutil.copytree(sdir, r.dir / "rex-state-backup")
            r.log(f"backed up saved sessions from {sdir}")
    except OSError as e:
        r.log(f"warning: couldn't back up saved sessions: {e}")

    if not wait_for(lambda: server_info() is not None, RECONNECT_WAIT):
        r.log(f"no reconnect from the Rex app in {RECONNECT_WAIT:.0f}s; starting the server here")
        try:
            subprocess.run(["rex", "server", "start"], capture_output=True, text=True, timeout=60)
        except (subprocess.TimeoutExpired, OSError) as e:
            r.log(f"warning: rex server start: {e}")
    new = server_info() if wait_for(lambda: server_info() is not None, START_WAIT) else None
    if not new:
        manual("FAIL: the server did not come back. Start it with `rex server start` or open the Rex app, then:")
        return 4
    r.log(f"server back: {new.get('rex_version')} pid {new.get('pid')}, {new.get('session_count')} sessions")
    upgraded = new.get("instance_id") != info.get("instance_id") and new.get("rex_version") == installed_version()
    if not upgraded:
        r.log(f"warning: the server is not a new instance of {installed_version()}; resuming agents anyway")

    failed: list[Pane] = []
    sent: list[Pane] = []
    for p in todo:
        try:
            def shell_ready() -> bool:
                proc = block_call(p.session, p.block, "process") or {}
                return (proc.get("foreground") or {}).get("name") in SHELLS
            if not wait_for(shell_ready, PANE_WAIT):
                raise RexError("restored pane has no shell prompt")
            time.sleep(2)  # let the prompt finish drawing
            rex("send", "-s", p.session, "-b", p.block, p.resume_cmd)
            rex("send-key", "-s", p.session, "-b", p.block, "enter")
            r.log(f"resumed {p.label}")
            sent.append(p)
        except Exception as e:  # keep going: every other pane still needs resuming
            r.log(f"FAIL {p.label}: {e}")
            failed.append(p)

    for p in sent:
        if not wait_for(lambda: resumed(p), PANE_WAIT, 2):
            r.log(f"verify {p.label}: NOT RUNNING the expected session")
            failed.append(p)
        else:
            r.log(f"verify {p.label}: ok")
    todo = failed
    if failed:
        manual(f"done with problems: {len(failed)} pane(s) need attention:")
        return 5
    if not upgraded:
        r.log(f"done: {len(sent)} agents resumed, but the server was NOT upgraded")
        return 7
    r.log(f"done: {len(sent)} agents resumed")
    return 0


def resumed(p: Pane) -> bool:
    """The pane runs the agent again, with the same conversation."""
    proc = block_call(p.session, p.block, "process") or {}
    fg = proc.get("foreground") or {}
    pid = fg.get("pid")
    if not pid:
        return False
    if p.kind == "pi":
        rec = read_record(p.block)
        return (valid_record(rec, pid, proc_start_ticks(pid)) and pid != p.fg_pid
                and (p.target is None or rec.get("sessionFile") == p.target))
    if p.kind == "hermes":
        return hermes_session(pid, proc_cmdline(pid))[0] == p.target
    return False


def prune_runs(keep: Path) -> None:
    runs = [d for d in sorted(RUNS.glob("*")) if d != keep]
    for old in runs[:-(KEEP_RUNS - 1)]:
        shutil.rmtree(old, ignore_errors=True)


# ----------------------------------------------------------------------- main

def caller_identity() -> str | None:
    """block:pid:start of the agent this command runs under, if REX_BLOCK really
    is our pane. Only that exact process is exempt from the busy check."""
    block, session = os.environ.get("REX_BLOCK"), os.environ.get("REX_SESSION")
    if not block or not session:
        return None
    fg = (block_call(session, block, "process") or {}).get("foreground") or {}
    if not fg.get("pid") or not is_ancestor(fg["pid"], os.getpid()):
        return None
    return pane_identity(block, fg["pid"])


def main() -> int:
    os.umask(0o077)  # logs and screen captures hold terminal contents
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", nargs="?", default="plan", choices=["plan", "run"])
    ap.add_argument("--dry-run", action="store_true", help="with run: check everything, change nothing")
    ap.add_argument("--wait-idle", type=float, default=0, metavar="MIN",
                    help="wait up to MIN minutes for busy agents to finish (default: don't wait)")
    ap.add_argument("--allow-unresumable", action="store_true",
                    help="restart even if some panes run programs that can't be resumed")
    ap.add_argument("--even-if-current", action="store_true", help="restart even if already up to date")
    ap.add_argument("--self-id", help=argparse.SUPPRESS)  # block:pid:start of the calling agent
    ap.add_argument("--run-dir", help=argparse.SUPPRESS)
    args = ap.parse_args()

    info = server_info()
    if not info:
        print("No Rex server is running; nothing to restart.")
        return 1
    running, installed = info.get("rex_version", "?"), installed_version()
    if args.self_id is None:
        args.self_id = caller_identity()

    if args.command == "plan":
        panes = inventory(args.self_id)
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

    if not is_ancestor(info.get("pid") or -1, os.getpid()):
        return do_run(args)

    # Inside the Rex server's process tree: stopping the server would kill us,
    # so check here, then hand the run to a transient systemd unit.
    if running == installed and not args.even_if_current:
        print(f"Server already runs {installed}; nothing to do.")
        return 0
    problems = blockers(inventory(args.self_id), args.allow_unresumable)
    if problems and (args.dry_run or not args.wait_idle):
        print("Not safe right now, nothing changed:\n  " + "\n  ".join(problems))
        return 2
    if args.dry_run:
        print("Dry run: preflight ok.")
        return 0
    stamp = new_run_name()
    run_dir = RUNS / stamp
    cmd = ["systemd-run", *([] if os.getuid() == 0 else ["--user"]),
           f"--unit=rex-safe-upgrade-{stamp}", "--collect", "-p", "Type=exec",
           f"--setenv=HOME={HOME}",
           f"--setenv=XDG_RUNTIME_DIR={os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')}",
           f"--setenv=PATH={os.environ.get('PATH', '/usr/bin:/bin')}",
           sys.executable, os.path.abspath(__file__), "run", f"--run-dir={run_dir}",
           f"--wait-idle={args.wait_idle}", f"--self-id={args.self_id or ''}"]
    cmd += [f for f, on in (("--allow-unresumable", args.allow_unresumable),
                            ("--even-if-current", args.even_if_current)) if on]
    subprocess.run(cmd, check=True)
    print(f"Started rex-safe-upgrade-{stamp}. This pane will close and come back resumed.")
    print(f"Log: {run_dir}/log.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
