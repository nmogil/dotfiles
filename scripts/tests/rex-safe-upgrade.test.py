#!/usr/bin/env python3
"""rex-safe-upgrade tests: planning, the full restart workflow, and the installer.

The tool runs as a real subprocess. Its only seam to Rex is the `rex` CLI, so
a stateful fake `rex` on PATH stands in for the server: it keeps state in a
JSON file, "restarts" by killing a real process, restores panes as shells, and
starts real processes when a resume command is typed. /proc inspection runs
against real processes.

The boundary that keeps these tests away from a real Rex server and systemd
is where they run: the Linux integration tests run only in an isolated
sandbox (a container, or a CI runner): REX_SAFE_UPGRADE_TEST_SANDBOX=1 must be
set, and the machine must have no rex binary, no Rex runtime directory under
/run/user and no user systemd bus. Otherwise they skip (or, with
REX_SAFE_UPGRADE_TEST_REQUIRE_SANDBOX=1, fail). On 2026-11-25 a run left
behind by a failed test stopped a real server; see docs/rex-safe-upgrade.md.

Inside the sandbox, defense in depth:
- Every subprocess gets a minimal environment built from scratch (no
  BASH_ENV/ENV, no host variables) and trusted absolute helper paths; bash
  always runs with --noprofile --norc, and no fixture runs a login shell.
- PATH holds only the fakes and tripwires for rex, systemctl and systemd-run
  that record any call that gets past them; every test fails if one fired.
- XDG_RUNTIME_DIR and HOME are inside the fixture root, and
  REX_SAFE_UPGRADE_TEST_ROOT puts the tool in test mode: it refuses to run
  unless rex and systemctl are the fakes, and never starts a systemd unit.
- This process is a child subreaper: every process a test starts, and every
  orphan they leave, stays its child, is reaped as it exits, and is killed
  (through pidfds, never a reused pid) before the test's files are removed.
"""
import ctypes
import fcntl
import glob
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'scripts/rex-safe-upgrade.py'
SETUP = ROOT / 'scripts/setup-rex-safe-upgrade.sh'

# Helpers come from fixed system directories, never from PATH.
TRUSTED_PATH = '/usr/bin:/bin'


def trusted(name):
    return shutil.which(name, path=TRUSTED_PATH)


PY = sys.executable
BASH, SH, SLEEP = trusted('bash'), trusted('sh'), trusted('sleep')
NOSTARTUP = ['--noprofile', '--norc']  # bash reads no startup files

# ----------------------------------------------------------- the sandbox gate

SANDBOX_ENV = 'REX_SAFE_UPGRADE_TEST_SANDBOX'
REQUIRE_ENV = 'REX_SAFE_UPGRADE_TEST_REQUIRE_SANDBOX'
HAS_PROC = Path('/proc/self/stat').exists()


def sandbox_problems():
    """Why this machine isn't an isolated sandbox for the integration tests."""
    if not HAS_PROC:
        return ['needs Linux /proc (rex-safe-upgrade inspects real processes); not available on this OS']
    out = []
    if os.environ.get(SANDBOX_ENV) != '1':
        out.append(f'{SANDBOX_ENV}=1 is not set: set it only in an isolated container or CI runner '
                   '(see docs/rex-safe-upgrade.md)')
    home = os.path.expanduser('~')
    dirs = {d for d in os.environ.get('PATH', '').split(':') if os.path.isabs(d)}
    dirs |= {'/usr/bin', '/bin', '/usr/local/bin', '/usr/sbin', '/sbin', '/snap/bin', '/opt/homebrew/bin',
             f'{home}/.local/bin', f'{home}/bin'}
    rex = sorted(str(Path(d, 'rex')) for d in dirs if Path(d, 'rex').exists())
    if rex:
        out.append('a rex binary is installed: ' + ', '.join(rex))
    runtime = sorted(glob.glob('/run/user/*/rex'))
    if runtime:
        out.append('a Rex runtime directory exists: ' + ', '.join(runtime))
    bus = sorted(glob.glob('/run/user/*/bus') + glob.glob('/run/user/*/systemd/private'))
    if bus or os.environ.get('DBUS_SESSION_BUS_ADDRESS'):
        out.append('a user systemd bus exists: ' + ', '.join(bus or [os.environ['DBUS_SESSION_BUS_ADDRESS']]))
    return out


SANDBOX_PROBLEMS = sandbox_problems()

# ------------------------------------------------------------------- fakes

FAKE_REX = textwrap.dedent(r"""
    #!@PY@ -I
    import json, os, shlex, signal, subprocess, sys, time
    from pathlib import Path
    path = os.environ["FAKE_REX_STATE"]
    st = json.load(open(path))
    args = [a for a in sys.argv[1:] if not a.startswith("--autostart")]
    def save():
        with open(path + ".tmp", "w") as f: json.dump(st, f)
        os.replace(path + ".tmp", path)
    def ticks(pid): return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
    def out(v): save(); print(json.dumps(v)); sys.exit(0)
    def fail(): save(); sys.exit(1)
    bound = args[:1] == ["-S"]
    if bound:  # an explicit server address must be this server's
        st["bound"].append(args[:4])
        if args[1] != st["endpoint"]: fail()
        args = args[2:]
    else:
        st["unbound"].append(args[:2])
        if st["route_flips"] and st["route_selected"] and args[:1] not in (["version"], ["whoami"]):
            # The default route now reaches another server, B, with no panes
            # (whoami still reaches A): whoami(A), inventory(B), whoami(A), stop(A).
            if args[:1] == ["ls"]: out({"sessions": []})
            fail()
        if args[:1] == ["whoami"]: st["route_selected"] = True
    def opt(name): return args[args.index(name) + 1]
    def blocks(): return [b for s in st["sessions"] for b in s["blocks"]]
    def session(): return next((s for s in st["sessions"] if s["session_id"] == opt("-s")), None)
    def block():  # only a block of the session named with -s
        b = next((b for b in (session() or {}).get("blocks", []) if b["block_id"] == opt("-b")), None)
        if b is None: fail()
        return b
    st["calls"].append(args[:2])
    cmd = args[:2]
    if cmd[:1] == ["version"]:
        if st["installed"] is None: sys.exit(1)
        print("rex " + st["installed"]); sys.exit(0)
    if cmd[:1] == ["whoami"]:
        if not st["running"]: fail()
        me = {"rex_version": st["running"], "pid": st["server_pid"], "instance_id": st["instance"],
              "endpoint": st["endpoint"], "session_count": len(st["sessions"])}
        if not bound and not st["first_answered"]:  # the default route may first reach another server
            st["first_answered"] = True; me.update(st["first_whoami"])
        out(me)
    if cmd[:1] == ["ls"]:
        st["ls_count"] += 1
        for bid, change in st["on_second_ls"].items():
            if st["ls_count"] == 2:
                b = next(b for b in blocks() if b["block_id"] == bid); b.update(change)
        out({"sessions": [{"session_id": s["session_id"], "label": s["label"]} for s in st["sessions"]]})
    if cmd == ["session", "inspect"]:
        out({"windows": next(s for s in st["sessions"] if s["session_id"] == args[2])["windows"]})
    if cmd == ["block", "ls"]:
        s = session()
        if s is None or s["session_id"] in st["fail_block_ls"]: fail()
        out({"blocks": s["blocks"]})
    if cmd == ["block", "call"]:
        b = block()
        if args[-1] in b.get("fail_calls", []): fail()
        out(b.get(args[-1], {}))
    if cmd[:1] == ["capture"]: block(); print("screen"); sys.exit(0)
    if cmd == ["server", "stop"]:
        if st["stop_hangs"]: save(); time.sleep(60)
        try:  # only the fake server this test started, never a reused pid
            if ticks(st["server_pid"]) == st["server_ticks"]: os.kill(st["server_pid"], signal.SIGTERM)
        except OSError: pass
        st["running"] = None
        for b in blocks():  # Rex restores every pane as a fresh shell
            b["process"] = {"foreground": {"name": "zsh", "pid": 1, "cwd": b["process"]["foreground"]["cwd"]}}
            b["program_status"] = {"records": []}
        if st["reconnect"]: st.update(running=st["comes_back_as"], instance=st["new_instance"])
        out({})
    save(); sys.stderr.write("fake rex: unsupported %r\n" % args); sys.exit(2)  # e.g. send: never typed
""").lstrip().replace('@PY@', PY).replace('@BASH@', BASH or '').replace('@SLEEP@', SLEEP or '')

# rexume's systemd user unit, as `systemctl --user` sees it. Calls go into the
# fake rex's call list, so their order against `rex server stop` is checkable.
# rexume: "active", "inactive", "missing" (not installed) or "unreachable"
# (no user manager).
FAKE_SYSTEMCTL = textwrap.dedent(r"""
    #!@PY@ -I
    import json, os, sys, time
    path = os.environ["FAKE_REX_STATE"]
    st = json.load(open(path))
    args = sys.argv[1:]
    st["calls"].append(["systemctl", *args])
    st["systemctl_runtime_dirs"].append(os.environ.get("XDG_RUNTIME_DIR"))
    def save():
        with open(path + ".tmp", "w") as f: json.dump(st, f)
        os.replace(path + ".tmp", path)
    def done(code, text=None, err=None):
        save()
        if text: print(text)
        if err: sys.stderr.write(err + "\n")
        sys.exit(code)
    if args[:1] != ["--user"] or args[2:] != ["rexume"]: done(1)
    if st["rexume"] == "unreachable": done(1, err="Failed to connect to bus: No such file or directory")
    if args[1] == "is-active":
        if st["rexume"] == "active": done(0, "active")
        done(4 if st["rexume"] == "missing" else 3, "inactive")
    if args[1] == "stop":
        if st["rexume_stop_fails"]: done(1, err="Job for rexume.service failed")
        for key, val in st["on_rexume_stop"].items():  # the world changing during the pause
            if key == "blocks":
                for b in (b for s in st["sessions"] for b in s["blocks"]): b.update(val.get(b["block_id"], {}))
            else:
                st[key] = val
        st["rexume"] = "inactive"
        if st["rexume_stop_hangs"]: save(); time.sleep(60)
        done(0)
    if args[1] == "start":
        if st["rexume_start_delay"]: save(); time.sleep(st["rexume_start_delay"])
        if st["rexume_start_fails"]: done(1, err="Job for rexume.service failed")
        st["rexume"] = "active"; done(0)
    done(1)
""").lstrip().replace('@PY@', PY)

# A stand-in for Pi: `node` with argv0 `pi`, as Pi shows up in /proc.
FAKE_PI = f'#!{PY} -I\nimport os, sys\nos.execv(sys.argv[1], ["pi", "60"])\n'

# Never real in a test: the tool's only ways to a Rex server or systemd.
GUARDED = ('rex', 'systemctl', 'systemd-run')
# Anything that resolves one of GUARDED past the fakes lands here instead.
# Shell builtins only: there is nothing else on the sandbox PATH.
TRIPWIRE = '#!@SH@\nprintf "%s\\n" "${0##*/} $*" >> "${0%/*}/calls.log"\nexit 1\n'.replace('@SH@', SH or '/bin/sh')
FAKE_SYSTEMD_RUN = f'#!{SH}\necho "fake systemd-run: refusing" >&2\nexit 1\n'
TEST_ROOT_MARKER = '.rex-safe-upgrade-test-root'


class Sandbox:
    """The environment every test runs commands in: minimal, built from
    scratch, with only the fixtures' and allowlisted tools on PATH."""

    def __init__(self, test, home, tools=(), fixture_root=False):
        trip = tempfile.TemporaryDirectory()
        test.addCleanup(trip.cleanup)  # after the tripwire check
        self.tripwire = Path(trip.name)
        for name in GUARDED:
            (self.tripwire / name).write_text(TRIPWIRE)
            (self.tripwire / name).chmod(0o755)
        toolbin = home / 'tools'  # real tools, by allowlist only
        toolbin.mkdir()
        for name in tools:
            real = PY if name == 'python3' else trusted(name)
            assert name not in GUARDED and real, name
            (toolbin / name).symlink_to(real)
        fakebin = home / 'bin' if fixture_root else None
        dirs = [d for d in (fakebin, toolbin, self.tripwire) if d]
        runtime = home / 'xdg-runtime'
        runtime.mkdir(mode=0o700)
        self.env = {'HOME': str(home), 'PATH': ':'.join(map(str, dirs)), 'XDG_RUNTIME_DIR': str(runtime),
                    'LANG': 'C.UTF-8'}
        if fixture_root:
            (home / TEST_ROOT_MARKER).write_text('')
            self.env['REX_SAFE_UPGRADE_TEST_ROOT'] = str(home)
        # The tripwires record (checked once, then the log is cleared).
        subprocess.run([str(self.tripwire / 'rex'), 'probe'], env={'PATH': ''})
        test.assertEqual(self.calls(), ['rex probe'])
        (self.tripwire / 'calls.log').unlink()
        # Without the fakes, nothing real is reachable: only the tripwires.
        for name in GUARDED:
            test.assertEqual(shutil.which(name, path=':'.join(map(str, dirs[-2:]))), str(self.tripwire / name))
            if fakebin:
                test.assertEqual(shutil.which(name, path=self.env['PATH']), str(fakebin / name))

    def calls(self):
        log = self.tripwire / 'calls.log'
        return log.read_text().splitlines() if log.exists() else []


# --------------------------------------------------------------- processes

def proc_stat(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    except (OSError, IndexError):
        return None


def start_ticks(pid):
    return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]


def children(pid, zombies=False):
    out = []
    for d in os.listdir('/proc'):
        st = proc_stat(d) if d.isdigit() else None
        if st and st[1] == str(pid) and (zombies or st[0] != 'Z'):
            out.append(int(d))
    return out


def alive(pid):
    st = proc_stat(pid)
    return bool(st) and st[0] != 'Z'


def signal_process(pid, sig):
    """Through a pidfd, so the signal reaches the process the pid named when
    the pidfd was opened, never a later one."""
    try:
        fd = os.pidfd_open(pid)
    except ProcessLookupError:
        return
    try:
        signal.pidfd_send_signal(fd, sig)
    except ProcessLookupError:
        pass
    finally:
        os.close(fd)


# Gives a new session a controlling terminal, then execs the program: no
# preexec_fn (unsafe once the reaper thread runs). Popen's start_new_session
# makes it a session leader first.
PTY_LAUNCHER = [PY, '-I', '-c', 'import fcntl, os, sys, termios\n'
                'fcntl.ioctl(0, termios.TIOCSCTTY, 0)\nos.execv(sys.argv[1], sys.argv[1:])']


def become_subreaper():
    """Orphans of anything this process starts reparent to it, not to init."""
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), 'prctl(PR_SET_CHILD_SUBREAPER)')


class Processes:
    """Every process a test starts (each in its own session, with the
    sandbox environment), and every orphan they leave behind: all stay this
    process's children. A thread reaps them as they exit, so a killed process
    vanishes from /proc. teardown() kills and reaps everything, repeating
    until nothing is left (bounded)."""

    def __init__(self, env):
        self.env, self.popens = env, {}
        self.lock, self.done = threading.Lock(), threading.Event()
        self.thread = threading.Thread(target=self._reap_loop, daemon=True)
        self.thread.start()

    def start(self, argv, **kw):
        for k, v in (('env', self.env), ('stdin', subprocess.DEVNULL), ('stdout', subprocess.DEVNULL),
                     ('stderr', subprocess.DEVNULL), ('start_new_session', True)):
            kw.setdefault(k, v)
        with self.lock:  # registered before the reaper can see it exit
            p = subprocess.Popen(argv, **kw)
            self.popens[p.pid] = p
        return p

    def _reap_loop(self):
        while not self.done.wait(0.02):
            with self.lock:
                for pid in children(os.getpid(), zombies=True):
                    if pid in self.popens:
                        self.popens[pid].poll()
                    elif proc_stat(pid) and proc_stat(pid)[0] == 'Z':
                        try:
                            os.waitpid(pid, os.WNOHANG)
                        except ChildProcessError:
                            pass

    def _reap_nowait(self, pid):
        if pid in self.popens:
            self.popens[pid].poll()
        else:
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass

    def teardown(self, timeout=20):
        """Kill and reap everything, never blocking past the deadline."""
        end = time.monotonic() + timeout
        self.done.set()
        self.thread.join(max(0.0, end - time.monotonic()))
        if self.thread.is_alive():
            raise AssertionError('the reaper thread did not stop')
        while True:
            kids = children(os.getpid(), zombies=True)
            if not kids:
                return
            if time.monotonic() > end:
                raise AssertionError(f'processes left behind: {kids}')
            for pid in kids:  # our unreaped children: their pids can't be reused yet
                signal_process(pid, signal.SIGKILL)
            for pid in kids:
                self._reap_nowait(pid)
            time.sleep(0.02)


S = 'session:00000000-0000-0000-0000-000000000001'
OTHER = 'session:00000000-0000-0000-0000-000000000009'
W = 'window:00000000-0000-0000-0000-000000000002'
# The fake Rex server: a copy of the interpreter named `rex`, so /proc shows
# a rex executable, holding the endpoint's unix socket (argv[1]: a path to
# listen on, "dgram:<path>" for a datagram socket, "-" for none).
# With more arguments it runs them as its child once <out>.go exists, and
# writes "<exit code>\n<output>" to <out>: a run started inside the server's
# process tree, as from a Rex pane.
FAKE_SERVER = ('import os, socket, subprocess, sys, time\n'
               'if sys.argv[1].startswith("dgram:"):\n'
               '    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); s.bind(sys.argv[1][6:])\n'
               'elif sys.argv[1] != "-":\n'
               '    s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen()\n'
               'if len(sys.argv) > 3:\n'
               '    out = sys.argv[2]\n'
               '    while not os.path.exists(out + ".go"): time.sleep(0.05)\n'
               '    r = subprocess.run(sys.argv[3:], capture_output=True, text=True)\n'
               '    open(out + ".tmp", "w").write(f"{r.returncode}\\n{r.stdout}{r.stderr}")\n'
               '    os.replace(out + ".tmp", out)\n'
               'time.sleep(600)\n')


def wait_until(pred, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    return False


def utc(t):
    return time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(t)) + f'.{int(t % 1 * 1e6):06d}Z'


def load_tool():
    spec = importlib.util.spec_from_file_location('rex_safe_upgrade', TOOL)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod  # dataclasses look their module up here
    spec.loader.exec_module(mod)
    return mod


class ShellModeTest(unittest.TestCase):
    """How a shell's argv is read; anything unrecognized fails closed."""

    def test_shell_forms(self):
        mode = load_tool().shell_mode
        cases = {
            'prompt': [['-zsh'], ['zsh'], ['/bin/zsh', '-l'], ['bash', '--login'], ['fish', '-i'],
                       ['bash', '--noprofile', '--norc', '-i']],
            'command': [['sh', '-lc', 'pi'], ['sh', '-c', 'x'], ['bash', '-O', 'extglob', '-c', 'x'],
                        ['bash', '+O', 'extglob', '-c', 'x'], ['zsh', '-o', 'extendedglob', '-c', 'x'],
                        ['fish', '--command', 'x'], ['fish', '--command=x'], ['fish', '-c', 'x'],
                        ['bash', '--noprofile', '--norc', '-lc', 'x']],
            'other': [['bash', 'script.sh'], ['bash', '--', 'x'], ['fish', '--init-command', 'x'],
                      ['bash', '-O', 'extglob'], ['bash', '--rcfile', 'f', '-i'], ['bash', '-s'],
                      ['zsh', '--emulate', 'sh'], ['fish', '-C', 'x']],
            'unknown': [[]],
        }
        for want, argvs in cases.items():
            for argv in argvs:
                self.assertEqual(mode(argv), want, argv)


@unittest.skipUnless(HAS_PROC, 'needs Linux /proc')
class OpenFdTargetsTest(unittest.TestCase):
    def test_an_fd_closed_while_listing_is_skipped(self):
        tool = load_tool()
        real = os.listdir
        with mock.patch.object(tool.os, 'listdir', lambda d: [*real(d), '987654']):  # gone by readlink
            targets = tool.open_fd_targets(os.getpid())
        self.assertIsNotNone(targets)
        self.assertTrue(targets)  # the fds that exist are still read
        with mock.patch.object(tool.os, 'listdir', mock.Mock(side_effect=PermissionError)):
            self.assertIsNone(tool.open_fd_targets(os.getpid()))


class SandboxRequirementTest(unittest.TestCase):
    @unittest.skipUnless(os.environ.get(REQUIRE_ENV) == '1', f'{REQUIRE_ENV}=1 not set')
    def test_integration_tests_run_in_an_isolated_sandbox(self):
        self.assertEqual(SANDBOX_PROBLEMS, [])


@unittest.skipUnless(HAS_PROC and not SANDBOX_PROBLEMS,
                     'integration tests need an isolated sandbox: ' + '; '.join(SANDBOX_PROBLEMS))
class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        become_subreaper()

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.fakebin = fakebin = self.home / 'bin'
        fakebin.mkdir()
        for name, src in (('rex', FAKE_REX), ('systemctl', FAKE_SYSTEMCTL), ('systemd-run', FAKE_SYSTEMD_RUN),
                          ('fake-pi', FAKE_PI)):
            (fakebin / name).write_text(src)
            (fakebin / name).chmod(0o755)
        self.fake_pi = fakebin / 'fake-pi'
        self.node = fakebin / 'node'  # Pi runs as node; a copy of sleep stands in
        shutil.copy(SLEEP, self.node)
        self.state_file = self.home / 'rex-state.json'
        # Cleanups run last-registered first: kill and reap everything, then
        # check the tripwires, then remove the temp dirs.
        self.sandbox = Sandbox(self, self.home, fixture_root=True)
        self.addCleanup(lambda: self.assertEqual(self.sandbox.calls(), [], 'a test reached a real rex/systemd'))
        self.env = dict(self.sandbox.env, FAKE_REX_STATE=str(self.state_file),
                        REX_SAFE_UPGRADE_RECONNECT_WAIT='3')
        self.procs = Processes(self.env)
        self.addCleanup(self.procs.teardown)
        (self.home / 'server').mkdir()
        self.rex_exe = self.home / 'server/rex'
        shutil.copy(os.path.realpath(PY), self.rex_exe)
        self.socket = self.home / 'rex.sock'
        self.endpoint = f'unix://{self.socket}'
        self.blocks = []
        self.records = self.home / '.local/state/rex-safe-upgrade/panes'
        self.records.mkdir(parents=True)

    def spawn(self, argv, **kw):
        return self.procs.start(argv, **kw).pid

    def prompt_shell(self):
        """A shell as a restored pane has it: started with no command
        (argv ["zsh"]), idle, no children."""
        return self.spawn(['zsh'], executable=SH, stdin=subprocess.PIPE)

    # -- panes --
    def pane(self, fg_name, pid, state='idle', app=None, cwd='/tmp', top=None):
        b = f'block:00000000-0000-0000-0000-{len(self.blocks) + 1:012d}'
        recs = ([{'state': state, 'app': app or fg_name, 'owner': {'pid': pid}, 'updated_at': utc(time.time())}]
                if state else [])
        self.blocks.append({
            'block_id': b, 'window_id': W, 'flavor': 'com.superlogical.terminal.shell',
            'process': {'foreground': {'name': fg_name, 'pid': pid, 'cwd': cwd}, 'child': {'pid': top or pid}},
            'program_status': {'records': recs}})
        return b

    def write_pi_record(self, b, pid, agent_dir=None, sfile=None):
        sfile = sfile or self.home / f'{b[-4:]}.jsonl'
        sfile.write_text('{}\n')
        rec = {'v': 2, 'kind': 'pi', 'block': b, 'pid': pid, 'startTicks': start_ticks(pid), 'cwd': '/tmp',
               'agentDir': agent_dir, 'sessionFile': str(sfile), 'hasMessages': True}
        self.records.joinpath(b.removeprefix('block:') + '.json').write_text(json.dumps(rec))

    def start_server(self, socket='-', run=None, out=None):
        """A fake Rex server process; see FAKE_SERVER."""
        extra = [str(out), *run] if run else []
        return self.spawn([str(self.rex_exe), '-I', '-c', FAKE_SERVER, str(socket), *extra])

    def spawn_in_terminal(self, argv):
        """argv as session leader of a new terminal, like a Rex pane's first
        program. self.pty is the terminal's other end, to type into."""
        master, slave = os.openpty()
        self.pty = master
        self.addCleanup(os.close, master)  # after teardown: the terminal outlives its processes
        p = self.procs.start([*PTY_LAUNCHER, *argv], stdin=slave, stdout=slave, stderr=slave, cwd='/tmp')
        os.close(slave)
        return p.pid

    def wrapper_pane(self, script='"$1" "$2"; exec "$3" 60', tty=True, kids=1, owner='pi', state='idle',
                     record=True, agent_dir=None, record_at=None, record_app='pi'):
        """A pane started as `rex new -- sh -lc '... pi ...; exec $SHELL -l'`: Rex sees the
        wrapper shell as the pane's program, and Pi runs as its child. (bash -lc
        with --noprofile: the same argv shape, without reading startup files.)"""
        argv = [BASH, *NOSTARTUP, '-lc', script, '_', str(self.fake_pi), str(self.node), SLEEP]
        wrapper = self.spawn_in_terminal(argv) if tty else self.spawn(argv, cwd='/tmp')
        node = lambda: [c for c in children(wrapper) if os.readlink(f'/proc/{c}/exe') == str(self.node)]
        self.assertTrue(wait_until(lambda: len(children(wrapper)) == kids and node()))
        pi = node()[0]
        time.sleep(0.2)  # the status below is written after Pi started
        b = self.pane('bash', wrapper, state=state, app='pi')
        rec = self.blocks[-1]['program_status']['records'][0]
        rec.update(app=record_app, updated_at=utc(record_at if record_at is not None else time.time()))
        if owner == 'pi':
            rec['owner']['pid'] = pi
        if record:
            self.write_pi_record(b, pi, agent_dir=agent_dir)
        return b, wrapper, pi

    def pi_pane(self, record=True, session_file=True, agent_dir=None, record_pid=None,
                state='idle', has_messages=True, sfile=None, old_schema=False, ticks=None, version=2):
        pid = self.spawn([BASH, *NOSTARTUP, '-c', f'exec -a pi {SLEEP} 60'])
        wait_until(lambda: Path(f'/proc/{pid}/cmdline').read_bytes().startswith(b'pi\0'))
        b = self.pane('node', pid, state=state, app='pi')
        if record:
            if session_file and not sfile:
                sfile = self.home / f'{b[-4:]}.jsonl'
                sfile.write_text('{}\n')
            rec = {'v': version, 'kind': 'pi', 'block': b, 'pid': record_pid or pid, 'startTicks': ticks or start_ticks(pid),
                   'cwd': '/tmp', 'agentDir': agent_dir, 'sessionFile': str(sfile) if sfile else None,
                   'hasMessages': has_messages}
            if old_schema:
                del rec['v'], rec['startTicks'], rec['hasMessages']
            self.records.joinpath(b.removeprefix('block:') + '.json').write_text(json.dumps(rec))
        return b

    def hermes_pane(self, resume='H-42'):
        pid = self.spawn([PY, '-I', '-c', 'import time; time.sleep(60)', 'hermes', '--tui', '--resume', resume])
        return self.pane('python3.12', pid, app='hermes')

    STATE_DEFAULTS = dict(
        running='1.0', installed='2.0', instance='old', new_instance='new', reconnect=True, endpoint=None,
        on_second_ls={}, comes_back_as=None, rexume='inactive', rexume_stop_fails=False,
        rexume_stop_hangs=False, rexume_start_delay=0, rexume_start_fails=False, on_rexume_stop={},
        stop_hangs=False, fail_block_ls=[], route_flips=False, first_whoami={})

    def write_state(self, server_run=None, **kw):
        """The fake server's state, with a real local server process behind
        it. With server_run, the server runs that command as its child once
        the state is written; its result lands in self.server_out."""
        unknown = set(kw) - set(self.STATE_DEFAULTS)
        assert not unknown, unknown
        st = {**self.STATE_DEFAULTS, **kw}
        st['comes_back_as'] = st['comes_back_as'] or st['installed']
        st['endpoint'] = st['endpoint'] or self.endpoint
        self.socket.unlink(missing_ok=True)
        self.server_out = self.home / 'server-run.txt'
        self.server_pid = self.start_server(self.socket, server_run, self.server_out)
        self.assertTrue(wait_until(lambda: self.socket.exists()))
        # Another session listed first, so finding a pane's session means searching.
        other = {'session_id': OTHER, 'label': 'other', 'blocks': [], 'windows': []}
        st.update(server_pid=self.server_pid, server_ticks=start_ticks(self.server_pid),
                  ls_count=0, calls=[], bound=[], unbound=[], route_selected=False, first_answered=False,
                  systemctl_runtime_dirs=[],
                  sessions=[other, {'session_id': S, 'label': 'work', 'blocks': self.blocks,
                                    'windows': [{'window_id': W, 'label': 'tab'}]}])
        self.state_file.write_text(json.dumps(st))
        if server_run:
            Path(f'{self.server_out}.go').touch()

    def state(self):
        return json.loads(self.state_file.read_text())

    def popen_tool(self, *args, env=None, cwd=None):
        env = {k: v for k, v in {**self.env, **(env or {})}.items() if v is not None}
        return self.procs.start([PY, '-I', str(TOOL), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env=env, cwd=cwd)

    def tool(self, *args, env=None, cwd=None):
        p = self.popen_tool(*args, env=env, cwd=cwd)
        out, err = p.communicate(timeout=120)
        return subprocess.CompletedProcess(p.args, p.returncode, out, err)

    def run_tool(self, *extra):
        self.run_dir = self.home / 'run'
        r = self.tool('run', f'--run-dir={self.run_dir}', *extra)
        plan_file = self.run_dir / 'plan.json'
        plan = {p['block']: p for p in json.loads(plan_file.read_text())} if plan_file.exists() else {}
        return r, plan

    def server_alive(self):
        return alive(self.server_pid)


class PlanTest(Base):
    def test_recorded_agents_and_idle_shells_are_safe(self):
        shell = self.pane('zsh', self.prompt_shell(), state=None)
        pi = self.pi_pane()
        fresh = self.pi_pane(session_file=False, has_messages=False)
        profile = self.pi_pane(agent_dir=str(self.home / '.pi/agent-work'))
        hermes = self.hermes_pane()
        self.write_state()
        r, plan = self.run_tool('--dry-run')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('preflight ok', r.stdout)
        self.assertTrue(self.server_alive())
        self.assertIsNone(plan[shell]['resume_cmd'])
        self.assertRegex(plan[pi]['resume_cmd'], r'^cd -- /tmp && pi --session \S+\.jsonl$')
        self.assertEqual(plan[fresh]['resume_cmd'], 'cd -- /tmp && pi')
        self.assertIn(f'PI_CODING_AGENT_DIR={self.home}/.pi/agent-work pi --session', plan[profile]['resume_cmd'])
        self.assertEqual(plan[hermes]['resume_cmd'], 'cd -- /tmp && hermes --tui --resume H-42')

    def assert_blocked(self, *needles, extra=()):
        self.write_state()
        r, _ = self.run_tool(*extra)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn('nothing changed', r.stdout)
        for n in needles:
            self.assertIn(n, r.stdout)
        self.assertTrue(self.server_alive())
        self.assertNotIn(['server', 'stop'], self.state()['calls'])
        return r

    def test_unrecorded_pi_blocks_with_reload_hint(self):
        self.pi_pane(record=False)
        self.pi_pane(record_pid=1)  # record left by an earlier pi in this pane
        self.pi_pane(old_schema=True)  # record from an older recorder
        self.pi_pane(ticks='1')  # same pid, different process (pid reused)
        self.pi_pane(version=1)  # unknown record format
        r = self.assert_blocked()
        self.assertEqual(r.stdout.count('type /reload in that pane'), 5, r.stdout)

    def test_safety_problems_are_not_waivable(self):
        self.pi_pane()
        self.blocks[-1]['fail_calls'] = ['program_status']
        shared = self.home / 'shared.jsonl'
        shared.write_text('{}\n')
        self.pi_pane(sfile=shared)
        self.pi_pane(sfile=shared)
        self.pi_pane()
        self.blocks[-1]['program_status']['records'][0]['owner']['pid'] = 1  # status from another process
        self.assert_blocked("couldn't read the pane's state", 'same conversation open in another pane',
                            "pi hasn't reported whether it's busy", extra=['--allow-unresumable'])

    def test_unknown_busy_state_is_never_waived(self):
        self.pi_pane(record=False)  # already a waivable problem...
        self.blocks[-1]['program_status']['records'][0]['owner']['pid'] = 1  # ...and no status of its own
        self.assert_blocked("pi hasn't reported whether it's busy", extra=['--allow-unresumable'])

    def test_status_from_another_process_is_ignored(self):
        self.pi_pane(state='working')
        recs = self.blocks[-1]['program_status']['records']
        recs.insert(0, {'state': 'idle', 'owner': {'pid': 1}})  # left over from an earlier program
        self.assert_blocked('pi is working')

    def test_lost_session_file_blocks_but_empty_session_does_not(self):
        self.pi_pane(sfile=self.home / 'deleted.jsonl', has_messages=True)
        self.assert_blocked("recorded session file is missing")

    def test_unknown_program_blocks_unless_allowed(self):
        self.pane('sleep', self.spawn([SLEEP, '60']))
        self.assert_blocked("'sleep' is running and can't be resumed")
        r, _ = self.run_tool('--dry-run', '--allow-unresumable')
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_background_job_under_idle_shell_blocks(self):
        shell = self.spawn([BASH, *NOSTARTUP, '-c', f'{SLEEP} 60 & wait'])
        self.pane('bash', shell, state=None)
        self.assert_blocked('background processes would be stopped: sleep')

    def test_unreadable_pane_blocks(self):
        b = self.pi_pane()
        self.blocks[-1]['fail_calls'] = ['program_status']
        self.assert_blocked("couldn't read the pane's state")
        del b

    def test_same_conversation_in_two_panes_blocks(self):
        shared = self.home / 'shared.jsonl'
        shared.write_text('{}\n')
        self.pi_pane(sfile=shared)
        self.pi_pane(sfile=shared)
        self.assert_blocked('same conversation open in another pane')

    def test_busy_agent_blocks_except_the_invoking_pane(self):
        busy = self.pi_pane(state='working')
        self.assert_blocked('pi is working')
        pid = self.blocks[-1]['process']['foreground']['pid']
        r, _ = self.run_tool('--dry-run', f'--self-id={busy}:{pid}:{start_ticks(pid)}')
        self.assertEqual(r.returncode, 0, r.stdout)
        # Naming the pane alone, or a different process, exempts nothing.
        for forged in (busy, f'{busy}:{pid}:1'):
            r, _ = self.run_tool('--dry-run', f'--self-id={forged}')
            self.assertEqual(r.returncode, 2, r.stdout)

    def test_waiting_for_input_counts_as_busy(self):
        self.pi_pane(state='blocked')
        self.assert_blocked('pi is blocked')

    def test_up_to_date_server_is_left_alone(self):
        self.pane('sleep', self.spawn([SLEEP, '60']))  # would block, but is never reached
        self.write_state(running='2.0', installed='2.0')
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 0)
        self.assertIn('nothing to do', r.stdout)
        r = self.tool()
        self.assertIn('(up to date)', r.stdout)
        self.assertIn('Nothing to do.', r.stdout)

    def test_plan_mode_reports_blockers(self):
        self.pi_pane()
        self.pane('sleep', self.spawn([SLEEP, '60']))
        self.write_state()
        r = self.tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('(restart needed)', r.stdout)
        self.assertIn('resume via pane record', r.stdout)
        self.assertIn('Not safe right now', r.stdout)
        self.assertNotIn('rexume', r.stdout)

    def test_plan_mode_says_rexume_will_be_paused(self):
        self.pi_pane()
        self.write_state(rexume='active')
        r = self.tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('rexume is active and will be paused during the restart', r.stdout)
        self.assertEqual([c for c in self.state()['calls'] if c[0] == 'systemctl'],
                         [['systemctl', '--user', 'is-active', 'rexume']])

    def test_pi_started_by_sh_c_wrapper_is_resumed_like_any_pi(self):
        # Rex's status record may be owned by Pi itself or by the wrapper Rex
        # sees as the foreground program (snapshot.2513 does the latter).
        b1, _, pi1 = self.wrapper_pane(owner='pi')
        b2, _, pi2 = self.wrapper_pane(owner='wrapper', agent_dir=str(self.home / '.pi/agent-work'))
        self.write_state()
        r, plan = self.run_tool('--dry-run')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for b, pid in ((b1, pi1), (b2, pi2)):
            self.assertEqual((plan[b]['kind'], plan[b]['fg_pid'], plan[b]['fg_name']), ('pi', pid, 'node'))
            self.assertIsNone(plan[b]['problem'])
        self.assertRegex(plan[b1]['resume_cmd'], r'^cd -- /tmp && pi --session \S+\.jsonl$')
        self.assertIn(f'PI_CODING_AGENT_DIR={self.home}/.pi/agent-work pi --session', plan[b2]['resume_cmd'])

    def test_busy_pi_in_wrapper_blocks_unless_it_started_the_run(self):
        b, _, pi = self.wrapper_pane(state='working')
        self.assert_blocked('pi is working')
        r, _ = self.run_tool('--dry-run', f'--self-id={b}:{pi}:{start_ticks(pi)}')
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_wrapper_pi_without_a_record_needs_reload(self):
        self.wrapper_pane(record=False)
        self.assert_blocked('type /reload in that pane')

    def test_wrapper_with_other_processes_blocks(self):
        self.wrapper_pane(script='"$3" 60 & "$1" "$2"; exec "$3" 60', kids=2)
        self.assert_blocked('background processes would be stopped')

    def test_wrapper_child_outside_the_terminal_foreground_blocks(self):
        self.wrapper_pane(tty=False)
        self.assert_blocked('background processes would be stopped: node')

    def caller_plan(self, env, fail_block_ls=()):
        """Runs the plan from a busy "pi" (argv0 pi) in its own pane, next to
        someone else's busy Pi; returns the plan's output."""
        self.blocks.clear()
        out = self.home / 'out.txt'
        code = ('import subprocess, sys\n'
                'open(sys.argv[1], "w").write(subprocess.run(sys.argv[2:], capture_output=True, text=True).stdout)')
        b = f'block:00000000-0000-0000-0000-{len(self.blocks) + 1:012d}'
        caller_env = {**self.env, 'REX_BLOCK': b, **env}
        # The pane is described before the caller runs: it waits on its stdin.
        caller = self.procs.start([BASH, *NOSTARTUP, '-c', 'read -r _; exec -a pi "$@"', '_', PY, '-I', '-c', code,
                                   str(out), PY, '-I', str(TOOL)], env=caller_env, stdin=subprocess.PIPE, text=True)
        self.assertEqual(self.pane('node', caller.pid, state='working', app='pi', top=os.getpid()), b)
        self.pi_pane(state='working')  # someone else's busy agent
        self.write_state(fail_block_ls=list(fail_block_ls))
        self.write_pi_record(b, caller.pid)  # exec keeps the start time
        caller.stdin.write('go\n')
        caller.stdin.close()
        caller.wait(timeout=60)
        return out.read_text()

    def test_run_started_from_an_agent_pane_exempts_only_that_agent(self):
        # Rex preview.23 sets REX_BLOCK but no longer REX_SESSION. A stale
        # REX_SESSION, or a session that can't be listed, doesn't stop the search.
        for env, fail in (({}, ()), ({'REX_SESSION': S}, ()), ({'REX_SESSION': OTHER}, ()), ({}, (OTHER,))):
            with self.subTest(env=env, fail_block_ls=fail):
                text = self.caller_plan(env, fail)
                self.assertRegex(text, r'pi +working +resume via pane record \(this pane\)')
                self.assertEqual(text.count('(this pane)'), 1, text)
                self.assertEqual(text.count('pi is working'), 1, text)  # only the other one blocks
                if fail:  # and the session that can't be listed blocks the run
                    self.assertIn("couldn't list this session's panes from Rex", text)

    def test_shell_running_a_script_blocks(self):
        script = self.home / 'job.sh'
        script.write_text(f'{SLEEP} 60\n')
        self.pane('bash', self.spawn([BASH, *NOSTARTUP, str(script)]), state=None)
        self.assert_blocked("'bash' is running a script or command that can't be resumed")

    def test_unreadable_foreground_shell_is_never_waived(self):
        gone = self.spawn([SLEEP, '60'])
        signal_process(gone, signal.SIGKILL)
        self.assertTrue(wait_until(lambda: not Path(f'/proc/{gone}').exists()))
        self.pane('bash', gone, state=None)
        self.assert_blocked("couldn't read the foreground shell's command line", extra=['--allow-unresumable'])

    def test_wrapper_status_must_come_from_the_current_child(self):
        # A status owned by the wrapper counts only if it names Pi and was
        # written after Pi started; otherwise Pi's state is unknown.
        self.wrapper_pane(owner='wrapper', record_at=time.time() - 60)
        self.wrapper_pane(owner='wrapper', record_app='claude')
        r = self.assert_blocked(extra=['--allow-unresumable'])
        self.assertEqual(r.stdout.count("pi hasn't reported whether it's busy"), 2, r.stdout)

    def test_plan_reports_what_it_cannot_establish(self):
        self.pi_pane()
        self.write_state(rexume='unreachable', installed=None)
        r = self.tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Not safe right now', r.stdout)
        self.assertIn("couldn't tell whether rexume is running", r.stdout)
        self.assertIn("couldn't tell which Rex version is installed", r.stdout)

    def test_agent_beside_a_background_job_is_never_waived_when_busy_or_unknown(self):
        # Two children: the wrapper can't be promoted, but Pi's own status
        # (working here, missing in the second pane) still decides.
        self.wrapper_pane(script='"$3" 60 & "$1" "$2"; exec "$3" 60', kids=2, owner='pi', state='working')
        self.wrapper_pane(script='"$3" 60 & "$1" "$2"; exec "$3" 60', kids=2, owner='pi')
        self.blocks[-1]['program_status']['records'] = []
        r = self.assert_blocked(extra=['--allow-unresumable'])
        self.assertRegex(r.stdout, r"pi \(pid \d+\) is working")
        self.assertRegex(r.stdout, r"pi \(pid \d+\) hasn't reported whether it's busy")

    def script_pane_with_pi(self):
        """A pane whose foreground program is `bash job.sh`, with Pi as the
        script's child: Rex reports the script; Pi is one level down."""
        script = self.home / 'job.sh'
        script.write_text(f'"{self.fake_pi}" "{self.node}"\n{SLEEP} 60\n')
        sh = self.spawn([BASH, *NOSTARTUP, str(script)])
        pis = lambda: [c for c in children(sh) if os.readlink(f'/proc/{c}/exe') == str(self.node)]
        self.assertTrue(wait_until(pis))
        time.sleep(0.2)
        self.pane('bash', sh, state=None)
        return pis()[0]

    def test_agent_under_a_script_foreground_is_never_waived(self):
        # The script is a waivable finding; the Pi it runs is not.
        for state, want in (('working', r"pi \(pid \d+\) is working"),
                            (None, r"pi \(pid \d+\) hasn't reported whether it's busy")):
            with self.subTest(state=state):
                self.blocks.clear()
                pi = self.script_pane_with_pi()
                if state:
                    self.blocks[-1]['program_status']['records'] = [
                        {'state': state, 'app': 'pi', 'owner': {'pid': pi}, 'updated_at': utc(time.time())}]
                r = self.assert_blocked("'bash' is running a script or command", extra=['--allow-unresumable'])
                self.assertRegex(r.stdout, want)

    def test_one_wrapper_record_cannot_clear_two_unpromoted_agents(self):
        # Two Pi children (so no promotion) and one idle record owned by the
        # wrapper, written after both started: neither Pi has reported.
        self.wrapper_pane(script='"$1" "$2" & "$1" "$2"; exec "$3" 60', kids=2, owner='wrapper', record=False)
        r = self.assert_blocked(extra=['--allow-unresumable'])
        self.assertEqual(len(re.findall(r"pi \(pid \d+\) hasn't reported whether it's busy", r.stdout)), 2, r.stdout)

    def test_promoted_interactive_shell_with_a_background_job_blocks(self):
        # The wrapper's foreground child is an interactive shell (idle at its
        # prompt) that has a job of its own running in the background.
        wrapper = self.spawn_in_terminal([BASH, *NOSTARTUP, '-lc', '"$1" --noprofile --norc -i; exec "$2" 60',
                                          '_', BASH, SLEEP])
        inner = lambda: [c for c in children(wrapper) if os.readlink(f'/proc/{c}/exe') == os.path.realpath(BASH)]
        self.assertTrue(wait_until(inner))
        time.sleep(0.5)  # let it reach its prompt
        os.write(self.pty, f'{SLEEP} 600 &\n'.encode())
        self.assertTrue(wait_until(lambda: any(proc_stat(c) and Path(f'/proc/{c}/comm').read_text().strip() == 'sleep'
                                               for c in children(inner()[0]))))
        self.pane('bash', wrapper, state=None)
        self.assert_blocked('background processes would be stopped: sleep')

    # -- status that can't be trusted
    def test_idle_record_cannot_hide_a_working_wrapper_record(self):
        b, wrapper, _ = self.wrapper_pane(owner='pi')  # Pi says idle...
        self.blocks[-1]['program_status']['records'].append(  # ...the wrapper's record says working
            {'state': 'working', 'app': 'pi', 'owner': {'pid': wrapper}, 'updated_at': utc(time.time())})
        self.assert_blocked('pi is working', extra=['--allow-unresumable'])

    def test_status_without_a_state_blocks(self):
        self.pi_pane()
        del self.blocks[-1]['program_status']['records'][0]['state']
        self.assert_blocked('reported a status without a state', extra=['--allow-unresumable'])

    def test_background_job_cannot_make_missing_agent_status_waivable(self):
        top = self.spawn([BASH, *NOSTARTUP, '-c', f'{SLEEP} 60 & wait'])  # the pane's shell, with a job
        pi = self.pi_pane()
        self.blocks[-1]['process']['child']['pid'] = top
        self.blocks[-1]['program_status']['records'] = []  # and Pi reported nothing
        r = self.assert_blocked("pi hasn't reported whether it's busy", extra=['--allow-unresumable'])
        self.assertIn('background processes would be stopped: sleep', r.stdout)
        del pi

    def test_promoted_shell_running_a_command_is_not_an_idle_shell(self):
        # The wrapper's one foreground child is itself a shell running a command.
        script = '"$1" --noprofile --norc -c "\\"$2\\" 60; :"; exec "$2" 60'
        wrapper = self.spawn_in_terminal([BASH, *NOSTARTUP, '-lc', script, '_', BASH, SLEEP])
        self.assertTrue(wait_until(lambda: any(os.readlink(f'/proc/{c}/exe') == os.path.realpath(BASH)
                                               for c in children(wrapper))))
        self.pane('bash', wrapper, state=None)
        self.assert_blocked("'bash' is running a command that can't be resumed")

    # -- the sandbox itself
    def test_host_startup_files_do_not_reach_fixtures(self):
        leaked = self.home / 'leaked'
        rc = self.home / 'rc.sh'
        rc.write_text(f': > {leaked}\n')
        with mock.patch.dict(os.environ, {'BASH_ENV': str(rc), 'ENV': str(rc)}):
            self.pi_pane()
            self.wrapper_pane()
            self.hermes_pane()
            self.write_state()
            r, _ = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(leaked.exists(), 'a fixture read BASH_ENV/ENV from the host environment')

    def test_teardown_leaves_no_process_behind_even_mid_spawn(self):
        # Keeps starting children and orphans while it is being torn down.
        self.spawn([BASH, *NOSTARTUP, '-c', f'while :; do {SLEEP} 30 & ( {SLEEP} 30 & ); {SLEEP} 0.01; done'])
        self.assertTrue(wait_until(lambda: len(children(os.getpid())) > 10))
        seen = [(pid, start_ticks(pid)) for pid in children(os.getpid())]
        self.procs.teardown()
        self.assertEqual(children(os.getpid(), zombies=True), [])
        for pid, ticks in seen:
            st = proc_stat(pid)
            self.assertFalse(st and st[19] == ticks, f'{pid} survived teardown')

    def test_no_server(self):
        self.write_state(running=None)
        r = self.tool()
        self.assertEqual(r.returncode, 1)
        self.assertIn('No Rex server is running', r.stdout)


class RestartTest(Base):
    def setUp(self):
        super().setUp()
        self.shell = self.pane('zsh', self.prompt_shell(), state=None)
        self.pi = self.pi_pane()
        self.fresh = self.pi_pane(session_file=False, has_messages=False)
        self.hermes = self.hermes_pane()
        # Rex's saved sessions for this endpoint, to be backed up after stop.
        sdir = self.home / '.local/state/rex/servers' / hashlib.sha256(self.endpoint.encode()).hexdigest()
        sdir.mkdir(parents=True)
        (sdir / 'snapshot.db').write_text('saved')

    def log(self):
        return (self.run_dir / 'log.txt').read_text()

    def test_restart_lists_each_resume_command_and_types_nothing(self):
        # Rex can't show that a restored shell is at an empty prompt (a shell
        # blocked in `read` looks the same), so nothing may be typed.
        self.write_state()
        r, plan = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(self.server_alive())
        log = self.log()
        self.assertIn('nothing was typed', log)
        self.assertIn('done: server restarted on 2.0; 3 agent(s) to resume as listed', log)
        for b in (self.pi, self.fresh, self.hermes):  # same label: the block ID tells them apart
            self.assertIn(f"work / tab [session {S}, block {b}]: {plan[b]['resume_cmd']}", log)
        self.assertIn('`rex focus -s <session> <block>`', log)
        self.assertEqual((self.run_dir / 'rex-state-backup/snapshot.db').read_text(), 'saved')
        self.assertEqual([c for c in self.state()['calls'] if c[:1] in (['send'], ['send-key'])], [])
        self.assertEqual(os.stat(self.run_dir).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(self.run_dir / 'log.txt').st_mode & 0o777, 0o600)

    def test_server_that_never_returns_leaves_manual_steps_and_starts_nothing(self):
        # `rex server start` can't be told which address to serve, so the
        # tool doesn't start an unverifiable server itself.
        self.write_state(reconnect=False)
        r, plan = self.run_tool()
        self.assertEqual(r.returncode, 4)
        self.assertNotIn(['server', 'start'], self.state()['calls'])
        log = self.log()
        self.assertIn('no new Rex server answered', log)
        for b in (self.pi, self.fresh, self.hermes):
            self.assertIn(plan[b]['resume_cmd'], log)

    def test_server_that_comes_back_on_the_old_version_is_reported(self):
        self.write_state(comes_back_as='1.0')
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 7, r.stdout)
        self.assertIn('the server was NOT upgraded', self.log())
        self.assertIn('nothing was typed', self.log())  # the resume commands are still listed

    def test_change_during_preflight_aborts_before_stop(self):
        self.write_state(on_second_ls={self.hermes: {'program_status': {'records': [{'state': 'working'}]}}})
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn('changed before the stop', r.stdout)
        self.assertTrue(self.server_alive())

    def test_second_run_is_refused_while_one_is_in_progress(self):
        self.write_state()
        lock = self.home / '.local/state/rex-safe-upgrade/run.lock'
        with lock.open('w') as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            r, _ = self.run_tool()
        self.assertEqual(r.returncode, 6)
        self.assertTrue(self.server_alive())


    def test_wrapper_pane_is_resumed_and_verified(self):
        b, _, _ = self.wrapper_pane(agent_dir=str(self.home / '.pi/agent-work'))
        self.write_state()
        r, plan = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('4 agent(s) to resume as listed', self.log())
        self.assertIn('PI_CODING_AGENT_DIR=', plan[b]['resume_cmd'])
        self.assertIn(plan[b]['resume_cmd'], self.log())

    # -- rexume: another daemon that reopens agents after a restart
    def systemctl_calls(self):
        return [c[1:] for c in self.state()['calls'] if c[0] == 'systemctl']

    def test_active_rexume_is_paused_for_the_restart(self):
        self.write_state(rexume='active')
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.state()['calls']
        stop = calls.index(['systemctl', '--user', 'stop', 'rexume'])
        start = calls.index(['systemctl', '--user', 'start', 'rexume'])
        self.assertLess(stop, calls.index(['server', 'stop']))
        last_rex = max(i for i, c in enumerate(calls) if c[0] != 'systemctl')
        self.assertGreater(start, last_rex)  # after resume and verification
        self.assertEqual(self.state()['rexume'], 'active')
        self.assertEqual(set(self.state()['systemctl_runtime_dirs']), {self.env['XDG_RUNTIME_DIR']})
        log = self.log()
        self.assertIn('paused rexume', log)
        self.assertIn('started rexume again', log)

    def test_inactive_rexume_is_left_alone(self):
        self.write_state()
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(self.systemctl_calls(), [['--user', 'is-active', 'rexume']])
        self.assertNotIn('rexume', self.log())

    def test_rexume_that_will_not_stop_aborts_before_the_server_stops(self):
        self.write_state(rexume='active', rexume_stop_fails=True)
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 8, r.stdout)
        self.assertIn('nothing changed', self.log())
        self.assertTrue(self.server_alive())
        self.assertNotIn(['server', 'stop'], self.state()['calls'])
        self.assertEqual(self.state()['rexume'], 'active')

    def assert_rexume_restarted_after(self, code, **kw):
        self.write_state(rexume='active', **kw)
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, code, r.stdout)
        self.assertIn(['server', 'stop'], self.state()['calls'])
        self.assertEqual(self.systemctl_calls()[-1], ['--user', 'start', 'rexume'])
        self.assertEqual(self.state()['rexume'], 'active')
        self.assertIn('started rexume again', self.log())

    def test_rexume_is_started_again_when_the_server_does_not_return(self):
        self.assert_rexume_restarted_after(4, reconnect=False)

    def test_rexume_is_started_again_when_the_server_is_not_upgraded(self):
        self.assert_rexume_restarted_after(7, comes_back_as='1.0')

    def test_rexume_is_started_again_when_the_run_is_killed(self):
        self.write_state(rexume='active', stop_hangs=True)
        self.run_dir = self.home / 'run'
        p = self.popen_tool('run', f'--run-dir={self.run_dir}')
        self.assertTrue(wait_until(lambda: ['server', 'stop'] in self.state()['calls'], 30))
        p.send_signal(signal.SIGTERM)
        out = ''.join(p.communicate(timeout=30))
        self.assertNotEqual(p.returncode, 0, out)
        self.assertEqual(self.systemctl_calls()[-1], ['--user', 'start', 'rexume'], out)
        self.assertIn('started rexume again', self.log())

    # -- isolation: the 2026-11-25 incident and the layers against it
    def test_run_whose_fakes_vanish_never_reaches_another_rex(self):
        # A test failed while its run was in `rex server stop`; cleanup removed
        # the fakes and the run went on. It re-resolved `rex` on PATH, found
        # the real one, and stopped the real server. Now it must not find any.
        self.write_state(rexume='active', stop_hangs=True)
        self.run_dir = self.home / 'run'
        p = self.popen_tool('run', f'--run-dir={self.run_dir}')
        self.assertTrue(wait_until(lambda: ['server', 'stop'] in self.state()['calls'], 30))
        hung = children(p.pid)  # the fake rex, inside `server stop`
        shutil.rmtree(self.fakebin)
        for c in hung:
            signal_process(c, signal.SIGKILL)
        signal_process(self.server_pid, signal.SIGKILL)
        out = ''.join(p.communicate(timeout=60))
        self.assertEqual(p.returncode, 4, out)
        self.assertIn('no new Rex server answered', out)
        self.assertEqual(self.sandbox.calls(), [])

    def test_test_mode_refuses_anything_outside_the_fixture_root(self):
        self.write_state()
        elsewhere = self.home.parent / f'{self.home.name}-elsewhere'
        elsewhere.mkdir()
        self.addCleanup(shutil.rmtree, elsewhere)
        uid = os.getuid()
        for env in ({'PATH': f'{self.sandbox.tripwire}:{self.env["PATH"]}'},  # tripwire rex first
                    {'REX_SAFE_UPGRADE_TEST_ROOT': ''},
                    {'REX_SAFE_UPGRADE_TEST_ROOT': 'relative'},
                    {'REX_SAFE_UPGRADE_TEST_ROOT': '/usr'},  # names the real binaries' parent
                    {'REX_SAFE_UPGRADE_TEST_ROOT': str(elsewhere)},  # no marker
                    {'XDG_RUNTIME_DIR': f'/run/user/{uid}'},
                    {'XDG_RUNTIME_DIR': f'/var/run/user/{uid}'},
                    {'XDG_RUNTIME_DIR': str(elsewhere)},
                    {'XDG_RUNTIME_DIR': None},
                    {'HOME': str(elsewhere)},
                    {'DBUS_SESSION_BUS_ADDRESS': f'unix:path=/run/user/{uid}/bus'}):
            with self.subTest(env=env):
                r = self.tool('run', env=env)
                self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
                self.assertIn('test mode', r.stdout)
        self.assertEqual(self.state()['calls'], [])
        self.assertTrue(self.server_alive())

    def test_test_mode_refuses_a_fake_that_resolves_elsewhere(self):
        # Pinned paths are canonical: a symlink in bin/ to a rex elsewhere is
        # that rex, not a fake.
        self.write_state()
        real = self.home / 'not-bin'
        real.mkdir()
        (self.fakebin / 'rex').rename(real / 'rex')
        (self.fakebin / 'rex').symlink_to(real / 'rex')
        r = self.tool('run')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn('not a fake', r.stdout)
        self.assertEqual(self.state()['calls'], [])

    def test_an_empty_path_entry_never_finds_a_rex_in_the_working_directory(self):
        self.write_state()
        r = self.tool('run', '--dry-run', env={'PATH': ':' + self.env['PATH']}, cwd=self.sandbox.tripwire)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('preflight ok', r.stdout)

    def test_test_mode_never_starts_a_systemd_unit(self):
        # A run started inside the server's process tree (as from a Rex pane)
        # hands itself to a transient unit, which would drop the fakes.
        self.blocks.clear()
        self.write_state(server_run=[PY, '-I', str(TOOL), 'run'])
        self.assertTrue(wait_until(self.server_out.exists, 60))
        code, out = self.server_out.read_text().split('\n', 1)
        self.assertEqual(code, '2', out)
        self.assertIn('refusing to start a systemd unit', out)
        self.assertNotIn(['server', 'stop'], self.state()['calls'])
        # What it would have run: the canonical systemd-run, the selected
        # server's address, and a kill mode that lets recovery finish.
        cmd = out.split('Would run:\n', 1)[1].split()
        self.assertEqual(cmd[0], os.path.realpath(self.fakebin / 'systemd-run'))
        for want in (f'--endpoint={self.endpoint}', '--instance-id=old', f'--server-pid={self.server_pid}',
                     'KillMode=mixed', 'TimeoutStopSec=300'):
            self.assertIn(want, cmd)


    # -- only this machine's own, verified Rex server is ever stopped
    def test_remote_server_is_never_stopped(self):
        # A server reporting no panes at a remote or non-socket address.
        self.blocks.clear()
        for endpoint in ('https://rex.example.com:7443', 'tcp://10.0.0.5:7000', 'tailnet://vps',
                         'vps', 'unix://relative/server.sock'):
            with self.subTest(endpoint=endpoint):
                self.write_state(endpoint=endpoint)
                r, _ = self.run_tool()
                self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
                self.assertIn("isn't a local unix socket", r.stdout)
                self.assertNotIn(['server', 'stop'], self.state()['calls'])
                self.assertTrue(self.server_alive())
                r = self.tool()  # the plan says so too
                self.assertIn("not this machine's own Rex server", r.stdout)

    def test_first_answer_is_checked_before_anything_is_bound(self):
        # The default route first reaches another server that reports a path
        # which exists here too; -S <path> would then reach the local one.
        gone = self.spawn([SLEEP, '60'])
        signal_process(gone, signal.SIGKILL)
        self.assertTrue(wait_until(lambda: not Path(f'/proc/{gone}').exists()))
        for first, why in (({'instance_id': 'remote', 'pid': gone}, "isn't a process on this machine"),
                           ({'instance_id': 'remote'}, "isn't the one first checked")):
            with self.subTest(why=why):
                self.write_state(first_whoami=first)
                r, _ = self.run_tool()
                self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
                self.assertIn(why, r.stdout)
                self.assertNotIn(['server', 'stop'], self.state()['calls'])
                self.assertTrue(self.server_alive())

    def test_handoff_runs_only_on_the_server_it_was_started_for(self):
        self.write_state()
        for ident in ('--instance-id=someone-else', f'--server-pid={os.getpid()}'):
            with self.subTest(ident=ident):
                full = {'--instance-id': '--instance-id=old', '--server-pid': f'--server-pid={self.server_pid}'}
                full[ident.split('=')[0]] = ident
                r = self.tool('run', f'--endpoint={self.endpoint}', *full.values())
                self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
                self.assertIn("isn't the one the run was started for", r.stdout)
        self.assertNotIn(['server', 'stop'], self.state()['calls'])

    def test_socket_check_follows_the_listener_that_answers(self):
        self.blocks.clear()
        for case in ('datagram', 'unlinked listener'):
            with self.subTest(case=case):
                self.write_state()
                old = self.server_pid
                self.socket.unlink()  # the old listener keeps its name in /proc/net/unix
                if case == 'datagram':
                    pid = self.start_server(f'dgram:{self.socket}')  # a rex holding a datagram socket there
                else:
                    self.start_server(self.socket)  # another listener now answers at the path
                    pid = old
                self.assertTrue(wait_until(self.socket.exists))
                st = self.state()
                st.update(server_pid=pid)
                self.state_file.write_text(json.dumps(st))
                r, _ = self.run_tool()
                self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
                self.assertRegex(r.stdout, "doesn't hold the socket|answers as pid")
                self.assertNotIn(['server', 'stop'], self.state()['calls'])

    def test_explicit_endpoint_must_be_a_local_socket(self):
        self.write_state()
        r = self.tool('run', '--endpoint=tcp://10.0.0.5:7000')
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertEqual(self.state()['calls'], [])

    def test_server_pid_must_be_the_local_rex_holding_the_socket(self):
        self.blocks.clear()
        gone = self.spawn([SLEEP, '60'])
        signal_process(gone, signal.SIGKILL)
        self.assertTrue(wait_until(lambda: not Path(f'/proc/{gone}').exists()))
        for make, why in ((lambda: self.spawn([SLEEP, '60']), 'not rex'),
                          (lambda: self.start_server('-'), "doesn't hold the socket"),
                          (lambda: gone, "isn't a process on this machine")):
            with self.subTest(why=why):
                self.write_state()
                pid = make()
                st = self.state()
                st.update(server_pid=pid)
                self.state_file.write_text(json.dumps(st))
                r, _ = self.run_tool()
                self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
                self.assertIn(why, r.stdout)
                self.assertNotIn(['server', 'stop'], self.state()['calls'])

    # -- one server, start to finish
    def test_every_rex_call_goes_to_the_selected_server(self):
        self.write_state()
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        # Only the first whoami (which selects the server) and `rex version`
        # (the local CLI) go without -S.
        self.assertEqual([c for c in self.state()['unbound'] if c != ['version']], [['whoami', '--json']])

    def test_default_route_changing_mid_run_cannot_mix_servers(self):
        # whoami(A), then the default route reaches B (no panes): the run must
        # still inspect A, where an agent is working, and stop nothing.
        pid = self.blocks[1]['process']['foreground']['pid']
        self.blocks[1]['program_status']['records'] = [
            {'state': 'working', 'app': 'pi', 'owner': {'pid': pid}, 'updated_at': utc(time.time())}]
        self.write_state(route_flips=True)
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn('pi is working', r.stdout)
        self.assertNotIn(['server', 'stop'], self.state()['calls'])

    def test_replacement_without_a_complete_identity_is_not_trusted(self):
        self.write_state(new_instance=None)
        r, plan = self.run_tool()
        self.assertEqual(r.returncode, 4, r.stdout)
        self.assertIn('no new Rex server answered', self.log())
        self.assertIn(plan[self.pi]['resume_cmd'], self.log())

    def test_group_signal_cannot_kill_rexume_recovery(self):
        # SIGTERM to the run's whole process group (as a terminal or a unit
        # stop would send), again while rexume is being started.
        p = self.run_until(['server', 'stop'], rexume='active', stop_hangs=True, rexume_start_delay=2)
        os.killpg(p.pid, signal.SIGTERM)
        self.assertTrue(wait_until(lambda: ['systemctl', '--user', 'start', 'rexume'] in self.state()['calls']))
        os.killpg(p.pid, signal.SIGTERM)
        out = ''.join(p.communicate(timeout=30))
        self.assertEqual(p.returncode, 128 + signal.SIGTERM, out)
        self.assertEqual(self.state()['rexume'], 'active', out)

    def test_test_mode_refuses_a_bin_dir_outside_the_fixture_root(self):
        self.write_state()
        outside = self.home.parent / f'{self.home.name}-outside'
        outside.mkdir()
        self.addCleanup(shutil.rmtree, outside)
        self.fakebin.rename(outside / 'bin')
        self.fakebin.symlink_to(outside / 'bin')
        r = self.tool('run')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn('outside the fixture root', r.stdout)
        self.assertEqual(self.state()['calls'], [])

    # -- the last checks before the stop
    def test_stop_is_bound_to_the_checked_server(self):
        self.write_state()
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        bound = self.state()['bound']
        stop = bound.index(['-S', self.endpoint, 'server', 'stop'])
        self.assertEqual(bound[stop - 1], ['-S', self.endpoint, 'whoami', '--json'])

    def test_pane_turning_busy_while_rexume_pauses_aborts(self):
        pid = self.blocks[1]['process']['foreground']['pid']
        busy = {'program_status': {'records': [{'state': 'working', 'owner': {'pid': pid}}]}}
        self.write_state(rexume='active', on_rexume_stop={'blocks': {self.pi: busy}})
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn('pi is working', r.stdout)
        self.assertNotIn(['server', 'stop'], self.state()['calls'])
        self.assertEqual(self.systemctl_calls()[-1], ['--user', 'start', 'rexume'])
        self.assertEqual(self.state()['rexume'], 'active')

    def test_server_changing_at_the_final_check_aborts(self):
        self.write_state(rexume='active', on_rexume_stop={'instance': 'someone-else'})
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn('server changed before the stop', r.stdout)
        self.assertNotIn(['server', 'stop'], self.state()['calls'])
        self.assertEqual(self.state()['rexume'], 'active')

    def test_server_without_a_complete_identity_is_left_alone(self):
        self.write_state(instance=None)
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("didn't report its instance id", r.stdout)
        self.assertNotIn(['server', 'stop'], self.state()['calls'])

    def test_unknown_installed_version_aborts(self):
        self.write_state(installed=None, comes_back_as='2.0')
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("couldn't tell which Rex version is installed", r.stdout)
        self.assertNotIn(['server', 'stop'], self.state()['calls'])

    # -- typing into restored panes
    # -- rexume that can't be checked, stopped or started
    def test_rexume_whose_state_is_unknown_aborts(self):
        self.write_state(rexume='unreachable')
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 8, r.stdout)
        self.assertIn("couldn't tell whether rexume is running", r.stdout)
        self.assertEqual(self.systemctl_calls(), [['--user', 'is-active', 'rexume']])
        self.assertNotIn(['server', 'stop'], self.state()['calls'])

    def test_runtime_dir_that_is_not_ours_means_unknown(self):
        self.write_state(rexume='active')
        r, _ = self.run_tool_env({'XDG_RUNTIME_DIR': str(self.home / 'missing')})
        self.assertEqual(r.returncode, 8, r.stdout)
        self.assertEqual(self.systemctl_calls(), [])  # never asked a manager it can't identify

    def test_rexume_not_installed_is_left_alone(self):
        self.write_state(rexume='missing')
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(self.systemctl_calls(), [['--user', 'is-active', 'rexume']])

    def test_rexume_that_cannot_be_started_again_fails_the_run(self):
        self.write_state(rexume='active', rexume_start_fails=True)
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 8, r.stdout)
        self.assertIn("couldn't start rexume again", self.log())
        self.assertIn('done: server restarted', self.log())

    def run_until(self, call, **state):
        self.write_state(**state)
        self.run_dir = self.home / 'run'
        p = self.popen_tool('run', f'--run-dir={self.run_dir}')
        self.assertTrue(wait_until(lambda: call in self.state()['calls'], 30))
        return p

    def test_interrupt_while_rexume_is_stopping_starts_it_again(self):
        p = self.run_until(['systemctl', '--user', 'stop', 'rexume'], rexume='active', rexume_stop_hangs=True)
        p.send_signal(signal.SIGTERM)
        out = ''.join(p.communicate(timeout=30))
        self.assertEqual(p.returncode, 128 + signal.SIGTERM, out)
        self.assertEqual(self.systemctl_calls()[-1], ['--user', 'start', 'rexume'], out)
        self.assertEqual(self.state()['rexume'], 'active')
        self.assertNotIn(['server', 'stop'], self.state()['calls'])

    def test_repeated_signals_do_not_cut_recovery_short(self):
        p = self.run_until(['server', 'stop'], rexume='active', stop_hangs=True, rexume_start_delay=2)
        p.send_signal(signal.SIGTERM)
        self.assertTrue(wait_until(lambda: ['systemctl', '--user', 'start', 'rexume'] in self.state()['calls']))
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            p.send_signal(sig)
        out = ''.join(p.communicate(timeout=30))
        self.assertEqual(p.returncode, 128 + signal.SIGTERM, out)
        self.assertEqual(self.state()['rexume'], 'active', out)
        self.assertIn('started rexume again', self.log())

    def run_tool_env(self, env):
        self.run_dir = self.home / 'run'
        return self.tool('run', f'--run-dir={self.run_dir}', env=env), None


class InstallerTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        sandbox = Sandbox(self, self.home, ('bash', 'sh', 'grep', 'cmp', 'install', 'mkdir', 'dirname', 'python3'))
        self.addCleanup(lambda: self.assertEqual(sandbox.calls(), [], 'the installer reached rex/systemd'))
        self.env = sandbox.env
        self.tool = self.home / '.local/bin/rex-safe-upgrade'
        self.ext = self.home / '.pi/agent/extensions/rex-pane-session.ts'

    def setup(self, *args):
        return subprocess.run([BASH, *NOSTARTUP, str(SETUP), *args], capture_output=True, text=True, env=self.env)

    def test_apply_check_and_idempotence(self):
        self.assertNotEqual(self.setup('--check').returncode, 0)
        self.assertIn('Would install', self.setup().stdout)
        self.assertFalse(self.tool.exists())
        for _ in range(2):
            r = self.setup('--apply')
            self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.setup('--check').returncode, 0)
        self.assertTrue(os.access(self.tool, os.X_OK))
        self.assertTrue(self.ext.is_file())

    def test_updates_managed_copy(self):
        self.setup('--apply')
        self.tool.write_text(self.tool.read_text() + '\n# older managed version\n')
        self.assertEqual(self.setup('--apply').returncode, 0)
        self.assertEqual(self.setup('--check').returncode, 0)

    def test_refuses_foreign_files_without_partial_install(self):
        self.ext.parent.mkdir(parents=True)
        self.ext.write_text('// hand-written; mentions Managed by dotfiles: somewhere else\n')
        r = self.setup('--apply')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('not installed by dotfiles', r.stderr)
        self.assertIn('hand-written', self.ext.read_text())
        self.assertFalse(self.tool.exists())

    def test_marker_must_match_line_and_position(self):
        self.ext.parent.mkdir(parents=True)
        src = (ROOT / 'templates/pi-rex/rex-pane-session.ts').read_text().splitlines()[0]
        self.ext.write_text(f'// someone else\n{src}\n')
        self.assertNotEqual(self.setup('--apply').returncode, 0)
        self.assertTrue(self.ext.read_text().startswith('// someone else'))

    def test_respects_pi_agent_dir(self):
        self.env['PI_CODING_AGENT_DIR'] = str(self.home / 'work-agent')
        self.assertEqual(self.setup('--apply').returncode, 0)
        self.assertTrue((self.home / 'work-agent/extensions/rex-pane-session.ts').is_file())


if __name__ == '__main__':
    unittest.main()
