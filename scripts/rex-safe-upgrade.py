#!/usr/bin/env python3
# Managed by dotfiles: scripts/rex-safe-upgrade.py. Install: ./dot rex install --apply
"""Restart the local Rex server onto the installed Rex version without losing work.

Rex keeps sessions, tabs, panes and scrollback across a server restart, but
every program running in a pane is stopped. This tool works out which agent
conversation each pane has open, checks that nothing would be lost, restarts
the server, and lists the command that resumes each agent in its pane. Rex
can't show that a restored shell is at an empty prompt, so it types nothing.

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
import signal
import socket
import struct
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
IDLE_STATES = {"idle", "done", "-"}  # "-": no status (decided per program kind)
KEEP_RUNS = 8
# Seconds to wait for the Rex app to relaunch the server.
RECONNECT_WAIT = float(os.environ.get("REX_SAFE_UPGRADE_RECONNECT_WAIT", 90))
# rexume (github.com/Entwining/rexume) also reopens agents after a server
# restart. A run pauses its systemd user unit so the two don't both type.
REXUME_UNIT = "rexume"


# ------------------------------------------------------------ external tools

# Each external command is resolved once, to the canonical absolute path of
# an executable found in an absolute PATH entry, and always run from that
# path. A later lookup could find a different binary: when a test's fake
# `rex` directory was deleted under a still-running run, PATH fell through to
# the real /usr/bin/rex and stopped the real server (2026-11-25).
_BINS: dict[str, str | None] = {}

# Test mode: the test suite sets this to its fixture root, a directory holding
# TEST_ROOT_MARKER, the fakes in bin/, and HOME and XDG_RUNTIME_DIR. Defense in
# depth only; the suite's real boundary is running in an isolated sandbox.
TEST_ROOT_ENV = "REX_SAFE_UPGRADE_TEST_ROOT"
TEST_ROOT_MARKER = ".rex-safe-upgrade-test-root"
TEST_MODE = TEST_ROOT_ENV in os.environ


def resolve_bin(name: str) -> str | None:
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if not d or not os.path.isabs(d):  # "" and relative entries mean the cwd
            continue
        cand = os.path.join(d, name)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return os.path.realpath(cand)
    return None


def bin_path(name: str) -> str:
    if name not in _BINS:
        _BINS[name] = resolve_bin(name)
    path = _BINS[name]
    if not path:
        raise FileNotFoundError(f"{name}: not found on PATH")
    return path


def under(path: str, root: str) -> bool:
    path, root = os.path.realpath(path), os.path.realpath(root)
    return os.path.commonpath([path, root]) == root


def test_mode_problems() -> list[str]:
    """In test mode, everything this tool can reach must be a fixture: refuse
    to run otherwise. Resolves and pins rex and systemctl."""
    if not TEST_MODE:
        return []
    root = os.environ.get(TEST_ROOT_ENV, "")
    if not root or not os.path.isabs(root) or not os.path.isdir(root) or os.path.realpath(root) == "/":
        return [f"{TEST_ROOT_ENV}={root!r} is not an absolute fixture directory"]
    if not os.path.isfile(os.path.join(root, TEST_ROOT_MARKER)):
        return [f"{TEST_ROOT_ENV}={root!r} has no {TEST_ROOT_MARKER}"]
    out = []
    fakes = os.path.realpath(os.path.join(root, "bin"))
    if not under(fakes, root):
        return [f"{root}/bin resolves to {fakes}, outside the fixture root"]
    for name in ("rex", "systemctl"):
        found = _BINS[name] = resolve_bin(name)  # pinned: what is checked is what runs
        if not found or os.path.dirname(found) != fakes:
            out.append(f"{name} resolves to {found}, not a fake in {fakes}")
    for var in ("HOME", "XDG_RUNTIME_DIR"):
        val = os.environ.get(var, "")
        if not val or not os.path.isabs(val) or not under(val, root):
            out.append(f"{var}={val!r} is not inside the fixture root")
    if os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        out.append("DBUS_SESSION_BUS_ADDRESS is set")
    return out


# ---------------------------------------------------------------- rex helpers

class RexError(Exception):
    pass


# The server a run works on, as the address it reported. Once set, every rex
# call goes to exactly that address (`rex -S`), so a run can't inspect one
# server and stop another. Carried through the systemd-run handoff.
_ENDPOINT: str | None = None


def bind_endpoint(endpoint: str) -> None:
    global _ENDPOINT
    _ENDPOINT = endpoint


def rex(*args: str, timeout: int = 30) -> str:
    target = ["-S", _ENDPOINT] if _ENDPOINT and args[:1] != ("-S",) else []
    try:
        p = subprocess.run([bin_path("rex"), "--autostart=false", *target, *args], capture_output=True, text=True,
                           timeout=timeout)
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


def server_info(endpoint: str | None = None) -> dict | None:
    """`rex whoami`; with endpoint, of exactly the server at that address."""
    try:
        return rex_json(*(["-S", endpoint] if endpoint else []), "whoami", "--json")
    except RexError:
        return None


IDENTITY = ("instance_id", "pid", "endpoint")


def identity(info: dict | None) -> tuple | None:
    """(instance id, pid, endpoint), only when all three are known."""
    ids = tuple((info or {}).get(k) for k in IDENTITY)
    return ids if all(ids) else None


def same_server(a: dict | None, b: dict | None) -> bool:
    return identity(a) is not None and identity(a) == identity(b)


def socket_path(endpoint) -> str | None:
    """The socket path of a local unix endpoint (unix:///path), else None:
    tcp, tailnet, https, host labels and relative paths are all rejected."""
    if not isinstance(endpoint, str) or not endpoint.startswith("unix://"):
        return None
    path = endpoint[len("unix://"):]
    return path if path.startswith("/") and "\0" not in path else None


def listening_socket_inodes(path: str) -> set[str]:
    """Inodes of the listening stream sockets bound to path, from
    /proc/net/unix (a name alone also matches datagram sockets and unlinked
    listeners that kept it)."""
    inodes = set()
    try:
        lines = Path("/proc/net/unix").read_text().splitlines()[1:]
    except OSError:
        return inodes
    for line in lines:
        f = line.split(None, 7)  # Num RefCount Protocol Flags Type St Inode Path
        if len(f) == 8 and f[7] == path and f[4] == "0001" and int(f[3], 16) & 0x10000:  # stream, listening
            inodes.add(f[6])
    return inodes


def socket_peer(path: str) -> tuple[int, int] | None:
    """(pid, uid) of the process that listens on the socket that actually
    answers at path, from SO_PEERCRED; None if nothing accepts there."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(5)
            s.connect(path)
            pid, uid, _gid = struct.unpack("3i", s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                                              struct.calcsize("3i")))
            return pid, uid
    except OSError:
        return None


def local_server_problem(info: dict) -> str | None:
    """Why the server isn't verifiably this machine's own Rex server, or None.
    The endpoint must be a local unix socket, and the reported pid a local
    rex process of this account that holds that socket. A remote or
    unverifiable server is never stopped."""
    endpoint, pid = info.get("endpoint"), info.get("pid")
    path = socket_path(endpoint)
    if not path:
        return f"the server's address {endpoint!r} isn't a local unix socket (unix:///path)"
    if not isinstance(pid, int) or pid <= 1:
        return f"the server reported no usable pid ({pid!r})"
    try:
        exe = os.readlink(f"/proc/{pid}/exe").removesuffix(" (deleted)")  # deleted: the package was upgraded
        uid = os.stat(f"/proc/{pid}").st_uid
    except OSError:
        return f"server pid {pid} isn't a process on this machine that can be inspected"
    if os.path.basename(exe) != "rex":
        return f"server pid {pid} runs {exe}, not rex"
    if uid != os.getuid():
        return f"server pid {pid} runs as uid {uid}, not as this account"
    inodes = listening_socket_inodes(path)
    if not inodes:
        return f"no stream socket is listening at {path}"
    try:
        fds = {os.readlink(f"/proc/{pid}/fd/{fd}") for fd in os.listdir(f"/proc/{pid}/fd")}
    except OSError:
        return f"couldn't read server pid {pid}'s open files"
    if not any(f"socket:[{i}]" in fds for i in inodes):
        return f"server pid {pid} doesn't hold the socket at {path}"
    # The listener that actually answers at the path must be that process.
    peer = socket_peer(path)
    if peer is None:
        return f"nothing accepts connections at {path}"
    if peer != (pid, os.getuid()):
        return f"the socket at {path} answers as pid {peer[0]} (uid {peer[1]}), not server pid {pid}"
    return None


def installed_version() -> str:
    try:
        out = subprocess.run([bin_path("rex"), "version"], capture_output=True, text=True, timeout=30).stdout
    except (subprocess.TimeoutExpired, OSError):
        return "?"
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


def proc_stat(pid: int) -> list[str]:
    """Fields after the command name: state, ppid, pgrp, session, tty_nr, tpgid, ..."""
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    except (OSError, IndexError):
        return []


def proc_exe_name(pid: int) -> str:
    """Name of the running executable, as Rex reports it ("node" for Pi)."""
    try:
        return os.path.basename(os.readlink(f"/proc/{pid}/exe"))
    except OSError:
        return proc_name(pid)


def proc_cwd(pid: int) -> str | None:
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return None


def proc_children(pid: int) -> list[int]:
    """Live (not zombie) children, from /proc."""
    out = []
    for d in os.listdir("/proc"):
        if d.isdigit():
            st = proc_stat(int(d))
            if len(st) > 1 and st[1] == str(pid) and st[0] != "Z":
                out.append(int(d))
    return out


def proc_start_wall(pid: int) -> float | None:
    """Wall-clock start time, from the boot-relative start in /proc."""
    ticks = proc_start_ticks(pid)
    if ticks is None:
        return None
    since_start = time.clock_gettime(time.CLOCK_BOOTTIME) - int(ticks) / os.sysconf("SC_CLK_TCK")
    return time.time() - since_start


def descendants(pid: int) -> list[int]:
    todo, seen = [pid], []
    while todo:
        for c in proc_children(todo.pop()):
            seen.append(c)
            todo.append(c)
    return seen


# Shell options that take the next argument (bash, zsh, fish).
SHELL_OPTS_WITH_ARG = {"-O", "+O", "-o", "+o", "--rcfile", "--init-file", "--init-command"}
# Options that a shell showing a prompt may have been started with.
PROMPT_OPTS = {"-l", "--login", "-i", "--interactive", "-il", "-li", "--noprofile", "--norc", "--no-rcs"}


def shell_mode(argv: list[str]) -> str:
    """How a shell was started: "prompt" (interactive or login shell),
    "command" (`-c`, `-lc`, `-O extglob -c`, fish `--command`), "unknown"
    (empty argv), or "other" (a script, or anything not recognized). Only
    "prompt" and "command" are trusted; everything else fails closed."""
    if not argv:
        return "unknown"
    args, i, prompt = argv[1:], 0, True
    while i < len(args):
        a = args[i]
        if a == "--command" or a.startswith("--command="):
            return "command"
        if a in SHELL_OPTS_WITH_ARG:
            i, prompt = i + 2, False
            continue
        if a.startswith("--"):  # includes "--": a script or arguments follow
            if a not in PROMPT_OPTS:
                return "other"
        elif a.startswith("-") and len(a) > 1:
            if "c" in a[1:]:
                return "command"
            if a not in PROMPT_OPTS:
                prompt = False
        else:
            return "other"  # a script file or an unknown option form
        i += 1
    return "prompt" if prompt else "other"


def real_children(pid: int) -> list[int]:
    return [c for c in proc_children(pid) if not proc_name(c).startswith(SHELL_HELPERS)]


def resolve_foreground(proc: dict) -> tuple[dict, str | None, bool]:
    """The pane's foreground program from Rex's `process` call, with a problem
    (and whether it's hard) when it can't be trusted. When that program is a
    shell running a command (`rex new -- sh -lc 'pi ...; exec $SHELL -l'`),
    the program is the shell's one child, if that child shares the shell's
    terminal and session and is in the terminal's foreground process group;
    the result then has "wrapper": the shell's pid. A shell running a command
    with one child that doesn't qualify is left as is, so the child counts as
    a background process."""
    fg = proc.get("foreground") or {}
    pid = fg.get("pid")
    if not pid or fg.get("name") not in SHELLS:
        return fg, None, False
    mode = shell_mode(proc_cmdline(pid))
    if mode == "unknown":
        return fg, "couldn't read the foreground shell's command line", True
    if mode == "prompt":
        return fg, None, False
    if mode == "other":
        return fg, f"'{fg['name']}' is running a script or command that can't be resumed", False
    kids = real_children(pid)
    if not kids:
        return fg, f"'{fg['name']}' is running a command that can't be resumed", False
    if len(kids) > 1:
        return fg, None, False
    child, wst, cst = kids[0], proc_stat(pid), proc_stat(kids[0])
    if len(wst) < 6 or len(cst) < 6:
        return fg, "couldn't read the foreground shell's process state", True
    # state ppid pgrp session tty_nr tpgid: same session and terminal, and the
    # child's group is the terminal's foreground group.
    if cst[3] != wst[3] or cst[4] != wst[4] or cst[4] == "0" or int(cst[5]) <= 0 or cst[2] != cst[5]:
        return fg, None, False
    return ({"pid": child, "name": proc_exe_name(child), "cwd": proc_cwd(child) or fg.get("cwd"), "wrapper": pid},
            None, False)


def record_time(r: dict) -> float | None:
    """A status record's updated_at as a timestamp ("...T18:54:32.088573996Z")."""
    m = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?Z", str(r.get("updated_at") or ""))
    if not m:
        return None
    frac = float(m.group(2) or 0)
    return dt.datetime.fromisoformat(m.group(1) + "+00:00").timestamp() + frac


def attributed_to(r: dict, child: int, kind: str | None) -> bool:
    """A status record owned by a wrapper shell describes its child only if it
    was written after the child started and, for an agent, names it."""
    started, at = proc_start_wall(child), record_time(r)
    app = r.get("effective_app") or r.get("app")
    return (kind is None or app == kind) and started is not None and at is not None and at >= started + 0.05


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
        try:
            insp = rex_json("session", "inspect", sid, "--json")
            blocks = rex_json("block", "ls", "-s", sid, "--json").get("blocks", [])
        except RexError:  # panes we can't see might run anything: block the run
            panes.append(Pane(session=sid, session_label=slabel, window_label="?", block=f"session {sid}",
                              kind="unknown", problem="couldn't list this session's panes from Rex", hard=True))
            continue
        wlabels = {w.get("window_id"): w.get("label") or w.get("window_id", "")[-8:]
                   for w in insp.get("windows") or []}
        for b in blocks:
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


def add_problem(p: Pane, msg: str, hard: bool = False) -> None:
    p.problem = "; ".join(filter(None, [p.problem, msg]))
    p.hard = p.hard or hard


def agent_kind(fg_name: str, argv: list[str]) -> str | None:
    argv0 = (argv[0].split() or [""])[0] if argv else ""
    if fg_name == "node" and argv0.rsplit("/", 1)[-1] == "pi":
        return "pi"
    if fg_name.startswith("python") and "--tui" in argv and "hermes" in " ".join(argv):
        return "hermes"
    return None


def program_state(records: list[dict], fg: dict, kind: str | None) -> tuple[str, bool]:
    """(state, malformed) of the program running now, from the status records
    that describe it: those it owns, and behind a wrapper, those the wrapper
    owns that are attributable to it. Any record that isn't idle wins, so an
    idle record can't hide a working one; a state Rex didn't define counts as
    busy, and a record without a state makes the state unknown."""
    pid, wrapper = fg["pid"], fg.get("wrapper")
    mine = [r for r in records if (r.get("owner") or {}).get("pid") == pid]
    if wrapper:
        mine += [r for r in records if (r.get("owner") or {}).get("pid") == wrapper
                 and attributed_to(r, pid, kind)]
    if not mine:
        return "-", False
    states = [r.get("state") for r in mine]
    if any(not isinstance(st, str) or not st for st in states):
        return "unknown", True
    busy = [st for st in states if st not in ("idle", "done")]
    return (busy[0] if busy else states[0]), False


def inspect_pane(p: Pane) -> None:
    proc = block_call(p.session, p.block, "process")
    status = block_call(p.session, p.block, "program_status")
    if proc is None or status is None:
        p.kind = "unknown"
        add_problem(p, "couldn't read the pane's state from Rex", hard=True)
        return
    raw_fg = (proc.get("foreground") or {}).get("pid")
    fg, problem, hard = resolve_foreground(proc)
    top = (proc.get("child") or {}).get("pid")
    if problem:
        p.fg_name, p.fg_pid = fg.get("name", "?"), fg.get("pid")
        p.kind = "unknown"
        add_problem(p, problem, hard)
        return
    if not fg.get("pid"):
        if top:
            p.kind = "unknown"
            add_problem(p, "Rex reports no foreground program", hard=True)
        else:
            p.kind = "shell"  # pane has exited; nothing runs in it
        return
    p.fg_name, p.fg_pid = fg.get("name", "?"), fg["pid"]
    p.cwd = fg.get("cwd") or proc.get("home") or str(HOME)
    p.fg_ticks = proc_start_ticks(p.fg_pid)
    argv = proc_cmdline(p.fg_pid)
    kind = agent_kind(p.fg_name, argv)

    # Busy or unknown status first, as hard problems: no waivable finding
    # below may hide them.
    p.state, malformed = program_state(status.get("records") or [], fg, kind)
    if malformed:
        add_problem(p, "reported a status without a state", hard=True)
    if kind and p.state == "-":  # an agent we can't see the state of might be mid-task
        add_problem(p, f"{kind} hasn't reported whether it's busy", hard=True)

    # Jobs started from the pane's shell, from a shell running in front of it,
    # or from the shell a wrapper runs (an interactive shell's own jobs).
    shells = {pid for pid in (top, raw_fg, p.fg_pid) if pid and proc_name(pid) in SHELLS}
    extra = sorted({c for sh in shells for c in real_children(sh)} - {p.fg_pid, raw_fg})
    # An agent among them (say, Pi beside a background job in a wrapper that
    # couldn't be promoted) still has its busy and unknown states checked:
    # stopping it is never waivable when it is, or may be, mid-task.
    records = status.get("records") or []
    for c in extra:
        ckind = agent_kind(proc_exe_name(c), proc_cmdline(c))
        if not ckind:
            continue
        cstate, cmalformed = program_state(records, {"pid": c, "wrapper": raw_fg}, ckind)
        if cmalformed or cstate == "-":
            add_problem(p, f"{ckind} (pid {c}) hasn't reported whether it's busy", hard=True)
        elif cstate not in ("idle", "done"):
            add_problem(p, f"{ckind} (pid {c}) is {cstate}", hard=True)
    if extra:
        add_problem(p, "background processes would be stopped: " + ", ".join(sorted({proc_name(c) for c in extra})))

    if kind == "pi":
        classify_pi(p)
    elif kind == "hermes":
        classify_hermes(p, argv)
    elif p.fg_name in SHELLS and (not fg.get("wrapper") or shell_mode(argv) == "prompt"):
        p.kind = "unknown" if extra else "shell"  # a prompt (resolve_foreground checked the pane's own)
    elif p.fg_name in SHELLS:  # a shell behind a wrapper, running a command of its own
        p.kind = "unknown"
        add_problem(p, f"'{p.fg_name}' is running a command that can't be resumed")
    else:
        p.kind = "unknown"
        add_problem(p, f"'{p.fg_name}' is running and can't be resumed automatically")


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
        add_problem(p, "pi hasn't recorded its session (started before the current recorder); type /reload in that pane")
        return
    sfile = rec.get("sessionFile")
    p.source = "pane record"
    if sfile and not Path(sfile).is_file():
        if rec.get("hasMessages"):
            add_problem(p, f"pi's recorded session file is missing: {sfile}")
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
        add_problem(p, p.source)
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
                add_problem(p, "same conversation open in another pane: "
                            + ", ".join(o.label for o in group if o is not p), hard=True)


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


# ------------------------------------------------------------------ rexume

def user_manager_env() -> dict[str, str] | None:
    """Environment that points `systemctl --user` at this account's own user
    manager, or None if that can't be established. XDG_RUNTIME_DIR must be an
    absolute directory owned by this account (a root system unit gets it from
    the systemd-run handoff); an inherited session bus address is dropped so
    systemctl uses that directory."""
    env = {k: v for k, v in os.environ.items() if k != "DBUS_SESSION_BUS_ADDRESS"}
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime is None:
        runtime = f"/run/user/{os.getuid()}"
    try:
        ok = os.path.isabs(runtime) and os.stat(runtime).st_uid == os.getuid() and os.path.isdir(runtime)
    except OSError:
        ok = False
    if not ok:
        return None
    env["XDG_RUNTIME_DIR"] = runtime
    return env


def systemctl_user(*args: str) -> subprocess.CompletedProcess | None:
    env = user_manager_env()
    if env is None:
        return None
    try:
        # Own session: a signal sent to the run's process group (Ctrl+C, a
        # group SIGTERM) can't kill it, least of all `start` during recovery.
        return subprocess.run([bin_path("systemctl"), "--user", *args], capture_output=True, text=True,
                              timeout=120, env=env, start_new_session=True)
    except (subprocess.TimeoutExpired, OSError):
        return None


def rexume_state() -> tuple[str, str]:
    """("active" | "inactive" | "unknown", detail). Inactive only when the
    user manager answered that rexume isn't running or isn't installed; an
    unreachable manager, a timeout or an odd answer is "unknown"."""
    p = systemctl_user("is-active", REXUME_UNIT)
    if p is None:
        return "unknown", "couldn't run `systemctl --user` for this account's user manager"
    state = p.stdout.strip()
    if p.returncode == 0 and state in {"active", "activating", "reloading"}:
        return "active", state
    if p.returncode in (3, 4) and state in {"inactive", "failed", "unknown"}:
        return "inactive", state
    return "unknown", outcome(p)


def outcome(p: subprocess.CompletedProcess | None) -> str:
    if p is None:
        return "systemctl failed to run or timed out"
    return (p.stderr.strip() or p.stdout.strip() or f"exit {p.returncode}") if p.returncode else "ok"


def start_rexume(r: "Run") -> bool:
    p = systemctl_user("start", REXUME_UNIT)
    if p and p.returncode == 0:
        r.log("started rexume again (systemctl --user start rexume)")
        return True
    r.log(f"FAIL: couldn't start rexume again: {outcome(p)}. Start it with: systemctl --user start rexume")
    return False


class Interrupts:
    """While rexume is paused: the first SIGTERM, SIGHUP or SIGINT unwinds the
    run (SystemExit), so rexume is started again; once that recovery has
    begun, further signals are ignored until it is done."""
    SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)

    def __init__(self):
        self.recovering = False
        self.old = {sig: signal.signal(sig, self.handle) for sig in self.SIGNALS}

    def handle(self, signum, _frame):
        if not self.recovering:
            self.recovering = True
            raise SystemExit(128 + signum)

    def restore(self) -> None:
        for sig, handler in self.old.items():
            signal.signal(sig, handler)


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


def do_run(args, first: dict) -> int:
    lock = acquire_lock()
    if not lock:
        print("ABORT: another rex-safe-upgrade run is in progress; nothing changed", flush=True)
        return 6
    run_dir = Path(args.run_dir) if args.run_dir else RUNS / new_run_name()
    r = Run(run_dir)
    try:
        return run_locked(r, args, first)
    finally:
        prune_runs(keep=run_dir)


def run_locked(r: Run, args, first: dict) -> int:
    """first: the identity checked (as this machine's own server) before any
    call was bound to its address. Every later answer must be that server."""
    info = server_info()
    if not info:
        r.log("ABORT: no Rex server is running")
        return 1
    if not same_server(info, first):
        r.log(f"ABORT, nothing changed: the server at {first.get('endpoint')} isn't the one first checked "
              f"(instance {first.get('instance_id')}, pid {first.get('pid')})")
        return 3
    running, installed = info.get("rex_version", "?"), installed_version()
    r.log(f"running {running}, installed {installed}, server pid {info.get('pid')}")
    if installed == "?":
        r.log("ABORT, nothing changed: couldn't tell which Rex version is installed (`rex version`)")
        return 2
    if identity(info) is None:
        r.log("ABORT, nothing changed: the Rex server didn't report its instance id, pid and endpoint")
        return 3
    local = local_server_problem(info)
    if local:
        r.log(f"ABORT, nothing changed: not this machine's own Rex server: {local}")
        return 3
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
    return restart_and_resume(r, args, panes, info)


def restart_and_resume(r: Run, args, panes: list[Pane], info: dict) -> int:
    """Pauses rexume (if it runs) for the restart and starts it again on every
    way out once a stop was attempted. Can't tell whether it runs: abort."""
    state, detail = rexume_state()
    if state == "unknown":
        r.log(f"ABORT, nothing changed: couldn't tell whether rexume is running ({detail})")
        return 8
    if state == "inactive":
        return restart_phase(r, args, panes, info)

    interrupts = Interrupts()  # armed before the stop: rexume is restarted on every way out
    try:
        result = 1
        try:
            p = systemctl_user("stop", REXUME_UNIT)
            if not p or p.returncode != 0:
                r.log(f"ABORT, nothing changed: couldn't pause rexume (systemctl --user stop rexume): {outcome(p)}")
                result = 8
            else:
                r.log("paused rexume (systemctl --user stop rexume) so only this run resumes agents")
                result = restart_phase(r, args, panes, info)
        except SystemExit as e:
            r.log(f"interrupted (exit {e.code}); starting rexume again before exiting")
            result = e.code if isinstance(e.code, int) else 1
        finally:
            interrupts.recovering = True
            started = start_rexume(r)  # also after a failed stop, in case it stopped anyway
        return 8 if (not started and result == 0) else result
    finally:
        interrupts.restore()


def list_resume_commands(r: Run, todo: list[Pane]) -> None:
    """One line per pane, named by session and block ID: labels repeat."""
    for p in todo:
        r.log(f"  {p.label} [session {p.session}, block {p.block}]: {p.resume_cmd}")
    if todo:
        r.log("  Find a pane by its block ID with `rex block ls -s <session>`, "
              "or go to it with `rex focus -s <session> <block>`.")


def final_checks(r: Run, args, panes: list[Pane], info: dict) -> int | None:
    """Everything that blocks a run, checked again after rexume was paused
    (which can take minutes), immediately before the stop."""
    if not same_server(server_info(info["endpoint"]), info):
        r.log("ABORT, nothing changed: the Rex server changed before the stop")
        return 3
    final = inventory(args.self_id)
    problems = blockers(final, args.allow_unresumable)
    if problems or plan_key(final) != plan_key(panes):
        r.log("ABORT, nothing changed: panes changed before the stop. " + "; ".join(problems))
        return 2
    return None


def restart_phase(r: Run, args, panes: list[Pane], info: dict) -> int:
    todo = [p for p in panes if p.resume_cmd]

    def manual(reason: str) -> None:
        r.log(reason)
        list_resume_commands(r, todo)

    abort = final_checks(r, args, panes, info)
    if abort is not None:
        return abort
    # `rex server stop` can't name an instance, only an address: check the
    # server at that address once more, then stop exactly that address.
    # Remaining window: another server replacing this one at the same address
    # between these two commands would be the one stopped.
    endpoint, old_pid = info["endpoint"], info["pid"]
    if not same_server(server_info(endpoint), info):
        r.log("ABORT, nothing changed: the Rex server changed right before the stop")
        return 3
    local = local_server_problem(info)
    if local:
        r.log(f"ABORT, nothing changed: not this machine's own Rex server: {local}")
        return 3
    r.log(f"stopping server pid {old_pid} at {endpoint}")
    try:
        subprocess.run([bin_path("rex"), "-S", endpoint, "--autostart=false", "server", "stop"],
                       capture_output=True, text=True, timeout=120)
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

    # The Rex app reconnecting starts the new server through the login server.
    # `rex server start` can't be told which address to serve, so this tool
    # doesn't start one itself: an unverified server is no recovery.
    new = server_info() if wait_for(lambda: server_info() is not None, RECONNECT_WAIT) else None
    # The replacement must be a complete, new server at the same address.
    if not new or identity(new) is None or new.get("endpoint") != endpoint or same_server(new, info):
        manual(f"FAIL: no new Rex server answered at {endpoint} within {RECONNECT_WAIT:.0f}s. Open the Rex app "
               f"(or run `rex server start`, and check `rex whoami` reports {endpoint}), then:")
        return 4
    r.log(f"server back: {new.get('rex_version')} pid {new.get('pid')}, {new.get('session_count')} sessions")
    upgraded = new.get("rex_version") == installed_version()

    # Rex reports no state that shows a restored shell waiting at an empty
    # prompt: a shell with no children may be blocked in `read` or run any
    # builtin, and typed text would go to it. So nothing is typed.
    if todo:
        r.log("Rex can't show that a restored shell is at an empty prompt, so nothing was typed. "
              "In each pane, once its prompt shows, type:")
        list_resume_commands(r, todo)
    if not upgraded:
        r.log(f"done, but the server was NOT upgraded: it runs {new.get('rex_version')}, "
              f"installed is {installed_version()}")
        return 7
    r.log(f"done: server restarted on {new.get('rex_version')}; {len(todo)} agent(s) to resume as listed")
    return 0


def prune_runs(keep: Path) -> None:
    runs = [d for d in sorted(RUNS.glob("*")) if d != keep]
    for old in runs[:-(KEEP_RUNS - 1)]:
        shutil.rmtree(old, ignore_errors=True)


# ----------------------------------------------------------------------- main

def block_session(block: str) -> str | None:
    """The session holding a block. Rex preview.23 sets only REX_BLOCK in new
    terminals; `-s <block id>` resolves there but not on older servers. A
    session that can't be listed is skipped."""
    try:
        sessions = rex_json("ls", "--json").get("sessions") or []
    except RexError:
        return None
    for s in sessions:
        try:
            blocks = rex_json("block", "ls", "--json", "-s", s["session_id"]).get("blocks") or []
        except (RexError, KeyError, TypeError, AttributeError):
            continue
        if any(isinstance(b, dict) and b.get("block_id") == block for b in blocks):
            return s["session_id"]
    return None


def caller_identity() -> str | None:
    """block:pid:start of the agent this command runs under, if REX_BLOCK really
    is our pane. Only that exact process is exempt from the busy check.
    REX_SESSION is a hint: if it doesn't hold the block, search for it."""
    block = os.environ.get("REX_BLOCK")
    if not block:
        return None
    hint = os.environ.get("REX_SESSION")
    proc = block_call(hint, block, "process") if hint else None
    if proc is None:
        session = block_session(block)
        proc = block_call(session, block, "process") if session else None
    fg, problem, _ = resolve_foreground(proc or {})
    if problem or not fg.get("pid") or not is_ancestor(fg["pid"], os.getpid()):
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
    # The server the caller checked, carried through the systemd-run handoff.
    ap.add_argument("--endpoint", help=argparse.SUPPRESS)
    ap.add_argument("--instance-id", help=argparse.SUPPRESS)
    ap.add_argument("--server-pid", type=int, help=argparse.SUPPRESS)
    args = ap.parse_args()

    problems = test_mode_problems()
    if problems:
        print(f"rex-safe-upgrade: test mode ({TEST_ROOT_ENV}), refusing to run; nothing changed:\n  "
              + "\n  ".join(problems))
        return 2
    if args.endpoint is not None and not socket_path(args.endpoint):
        print(f"--endpoint {args.endpoint!r} isn't a local unix socket (unix:///path); nothing changed.")
        return 3
    info = server_info(args.endpoint)
    if not info:
        print("No Rex server is running; nothing to restart.")
        return 1
    if args.endpoint and info.get("endpoint") != args.endpoint:
        print(f"The server at {args.endpoint} reports a different address; nothing changed.")
        return 3
    if (args.instance_id, args.server_pid) != (None, None) and (
            (info.get("instance_id"), info.get("pid")) != (args.instance_id, args.server_pid)):
        print(f"The server at {args.endpoint} isn't the one the run was started for (instance "
              f"{args.instance_id}, pid {args.server_pid}); nothing changed.")
        return 3
    if args.command == "run":
        # Checked on this first answer, before anything is bound to its
        # address: a remote server may report a path that exists here too.
        if identity(info) is None:
            print("The Rex server didn't report its instance id, pid and endpoint; nothing changed.")
            return 3
        local = local_server_problem(info)
        if local:
            print(f"Not this machine's own Rex server ({local}); nothing changed.")
            return 3
    if info.get("endpoint"):
        bind_endpoint(info["endpoint"])  # every later rex call goes to this server
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
            return 0
        if installed == "?":
            problems.append("couldn't tell which Rex version is installed (`rex version`)")
        local = local_server_problem(info)
        if local:
            problems.append(f"not this machine's own Rex server: {local}")
        state, detail = rexume_state()
        if state == "active":
            print("rexume is active and will be paused during the restart (started again afterwards).")
        elif state == "unknown":
            problems.append(f"couldn't tell whether rexume is running ({detail})")
        if problems:
            print("Not safe right now:\n  " + "\n  ".join(problems))
        else:
            print("Safe to run:  rex-safe-upgrade run")
        if any(p.resume_cmd for p in panes):
            print("After the restart, type each agent's resume command in its pane; the run lists them.")
        return 0

    if not is_ancestor(info.get("pid") or -1, os.getpid()):
        return do_run(args, info)

    # Inside the Rex server's process tree: stopping the server would kill us,
    # so check here, then hand the run to a transient systemd unit.
    if running == installed and not args.even_if_current:
        print(f"Server already runs {installed}; nothing to do.")
        return 0
    if installed == "?":
        print("Couldn't tell which Rex version is installed (`rex version`); nothing changed.")
        return 2
    problems = blockers(inventory(args.self_id), args.allow_unresumable)
    if problems and (args.dry_run or not args.wait_idle):
        print("Not safe right now, nothing changed:\n  " + "\n  ".join(problems))
        return 2
    if args.dry_run:
        print("Dry run: preflight ok.")
        return 0
    stamp = new_run_name()
    run_dir = RUNS / stamp
    try:
        systemd_run = bin_path("systemd-run")
    except FileNotFoundError as e:
        print(f"{e}; nothing changed.")
        return 2
    # KillMode=mixed: stopping the unit sends SIGTERM to the run only, which
    # then starts rexume again (if it paused it) before exiting; the rest of
    # the unit is killed only after that, or after TimeoutStopSec.
    cmd = [systemd_run, *([] if os.getuid() == 0 else ["--user"]),
           f"--unit=rex-safe-upgrade-{stamp}", "--collect", "-p", "Type=exec",
           "-p", "KillMode=mixed", "-p", "TimeoutStopSec=300",
           f"--setenv=HOME={HOME}",
           f"--setenv=XDG_RUNTIME_DIR={os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')}",
           f"--setenv=PATH={os.environ.get('PATH', '/usr/bin:/bin')}",
           os.path.realpath(sys.executable), os.path.realpath(__file__), "run", f"--run-dir={run_dir}",
           f"--endpoint={info['endpoint']}", f"--instance-id={info['instance_id']}", f"--server-pid={info['pid']}",
           f"--wait-idle={args.wait_idle}", f"--self-id={args.self_id or ''}"]
    cmd += [f for f, on in (("--allow-unresumable", args.allow_unresumable),
                            ("--even-if-current", args.even_if_current)) if on]
    if TEST_MODE:  # a transient unit drops the test's environment, fakes included
        print("rex-safe-upgrade: test mode, refusing to start a systemd unit; nothing changed. Would run:\n  "
              + " ".join(shlex.quote(c) for c in cmd))
        return 2
    subprocess.run(cmd, check=True)
    print(f"Started rex-safe-upgrade-{stamp}. This pane will close and come back as a shell; "
          "the log lists the command that resumes each agent.")
    print(f"Log: {run_dir}/log.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
