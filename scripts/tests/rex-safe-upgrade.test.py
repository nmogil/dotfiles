#!/usr/bin/env python3
"""rex-safe-upgrade tests: planning, the full restart workflow, and the installer.

The tool runs as a real subprocess. Its only seam to Rex is the `rex` CLI, so
a stateful fake `rex` on PATH stands in for the server: it keeps state in a
JSON file, "restarts" by killing a real process, restores panes as shells, and
starts real processes when a resume command is typed. /proc inspection runs
against real processes. Nothing here touches a live Rex server.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import textwrap
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'scripts/rex-safe-upgrade.py'
SETUP = ROOT / 'scripts/setup-rex-safe-upgrade.sh'

FAKE_REX = textwrap.dedent('''\
    #!/usr/bin/env python3
    import json, os, shlex, signal, subprocess, sys
    from pathlib import Path
    path = os.environ["FAKE_REX_STATE"]
    st = json.load(open(path))
    args = [a for a in sys.argv[1:] if not a.startswith("--autostart")]
    def save(): json.dump(st, open(path, "w"))
    def out(v): save(); print(json.dumps(v)); sys.exit(0)
    def opt(name): return args[args.index(name) + 1]
    def blocks(): return [b for s in st["sessions"] for b in s["blocks"]]
    def block(): return next(b for b in blocks() if b["block_id"] == opt("-b"))
    def detached(argv):
        p = subprocess.Popen(["bash", "-c", 'exec "$@" >/dev/null 2>&1 & echo $!', "_", *argv], stdout=subprocess.PIPE, text=True)
        pid = int(p.stdout.read()); p.wait(); st["spawned"].append(pid); return pid
    st["calls"].append(args[:2])
    cmd = args[:2]
    if cmd[:1] == ["version"]: print("rex " + st["installed"]); sys.exit(0)
    if cmd[:1] == ["whoami"]:
        if not st["running"]: sys.exit(1)
        out({"rex_version": st["running"], "pid": st["server_pid"], "instance_id": st["instance"],
             "endpoint": st["endpoint"], "session_count": len(st["sessions"])})
    if cmd[:1] == ["ls"]:
        st["ls_count"] += 1
        for bid, change in st.get("on_second_ls", {}).items():
            if st["ls_count"] == 2:
                b = next(b for b in blocks() if b["block_id"] == bid); b.update(change)
        out({"sessions": [{"session_id": s["session_id"], "label": s["label"]} for s in st["sessions"]]})
    if cmd == ["session", "inspect"]:
        out({"windows": next(s for s in st["sessions"] if s["session_id"] == args[2])["windows"]})
    if cmd == ["block", "ls"]:
        out({"blocks": next(s for s in st["sessions"] if s["session_id"] == opt("-s"))["blocks"]})
    if cmd == ["block", "call"]:
        b = block()
        if args[-1] in b.get("fail_calls", []): sys.exit(1)
        out(b.get(args[-1], {}))
    if cmd[:1] == ["capture"]: print("screen"); sys.exit(0)
    if cmd == ["server", "stop"]:
        if st["stop_hangs"]: save(); import time; time.sleep(60)
        os.kill(st["server_pid"], signal.SIGTERM)
        st["running"] = None
        for b in blocks():  # Rex restores every pane as a fresh shell
            fg = st["restore_as"].get(b["block_id"], {"name": "zsh", "pid": 1})
            b["process"] = {"foreground": {**fg, "cwd": b["process"]["foreground"]["cwd"]}}
            b["program_status"] = {"records": []}
        if st["reconnect"]: st.update(running=st["comes_back_as"], instance="new")
        out({})
    if cmd == ["server", "start"]:
        if st["start_works"]: st.update(running=st["comes_back_as"], instance="new")
        out({})
    if cmd[:1] == ["send"]:
        if opt("-b") in st["fail_send"]: save(); sys.exit(1)
        block()["typed"] = args[-1]; out({})
    if cmd[:1] == ["send-key"]:
        b = block(); typed = shlex.split(b.pop("typed"))
        cwd = b["process"]["foreground"]["cwd"]
        if "pi" in typed:
            pid = detached(["bash", "-c", "exec -a pi sleep 60"])
            sfile = typed[typed.index("--session") + 1] if "--session" in typed else None
            if b["block_id"] in st["resume_wrong"]: sfile = "/elsewhere.jsonl"
            rec = Path(os.environ["HOME"], ".local/state/rex-safe-upgrade/panes", b["block_id"].removeprefix("block:") + ".json")
            ticks = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
            if b["block_id"] in st["resume_incomplete"]: ticks = None
            rec.write_text(json.dumps({"v": 2, "pid": pid, "startTicks": ticks, "sessionFile": sfile, "hasMessages": True}))
            b["process"] = {"foreground": {"name": "node", "pid": pid, "cwd": cwd}}
        elif "hermes" in typed:
            pid = detached([sys.executable, "-c", "import time; time.sleep(60)", "hermes", *typed[typed.index("--tui"):]])
            b["process"] = {"foreground": {"name": "python3", "pid": pid, "cwd": cwd}}
        out({})
    sys.stderr.write("fake rex: unsupported %r\\n" % args); sys.exit(2)
''')

# rexume's systemd user unit, as `systemctl --user` sees it. Calls go into the
# fake rex's call list, so their order against `rex server stop` is checkable.
FAKE_SYSTEMCTL = textwrap.dedent('''\
    #!/usr/bin/env python3
    import json, os, sys
    path = os.environ["FAKE_REX_STATE"]
    st = json.load(open(path))
    args = sys.argv[1:]
    st["calls"].append(["systemctl", *args])
    st["systemctl_runtime_dirs"].append(os.environ.get("XDG_RUNTIME_DIR"))
    def done(code, text=None):
        json.dump(st, open(path, "w"))
        if text: print(text)
        sys.exit(code)
    if args[:1] != ["--user"] or args[2:] != ["rexume"]: done(1)
    if args[1] == "is-active": done(0 if st["rexume"] == "active" else 3, st["rexume"])
    if args[1] == "stop":
        if st["rexume_stop_fails"]: done(1)
        st["rexume"] = "inactive"; done(0)
    if args[1] == "start": st["rexume"] = "active"; done(0)
    done(1)
''')

# A stand-in for Pi: `node` with argv0 `pi`, as Pi shows up in /proc.
FAKE_PI = textwrap.dedent('''\
    #!/usr/bin/env python3
    import os, sys
    os.execv(sys.argv[1], ["pi", "60"])
''')

S = 'session:00000000-0000-0000-0000-000000000001'
W = 'window:00000000-0000-0000-0000-000000000002'
ENDPOINT = 'unix:///tmp/fake-rex.sock'


def start_ticks(pid):
    return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]


def detached_pid(argv, env=None):
    """A real process the test doesn't parent, so it vanishes from /proc when killed."""
    p = subprocess.run(['bash', '-c', 'exec "$@" >/dev/null 2>&1 & echo $!', '_', *argv],
                       capture_output=True, text=True, check=True, env=env)
    return int(p.stdout)


def children(pid):
    out = subprocess.run(['pgrep', '-P', str(pid)], capture_output=True, text=True).stdout
    return [int(x) for x in out.split()]


def wait_until(pred, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    return False


# The planner and restart workflow inspect real processes through /proc
# (Linux only). The installer tests below run everywhere.
HAS_PROC = Path('/proc/self/stat').exists()


@unittest.skipUnless(HAS_PROC, 'needs Linux /proc (rex-safe-upgrade inspects real processes); not available on this OS')
class Base(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        fakebin = self.home / 'bin'
        fakebin.mkdir()
        for name, src in (('rex', FAKE_REX), ('systemctl', FAKE_SYSTEMCTL), ('fake-pi', FAKE_PI)):
            (fakebin / name).write_text(src)
            (fakebin / name).chmod(0o755)
        self.fake_pi = fakebin / 'fake-pi'
        self.node = fakebin / 'node'  # Pi runs as node; a copy of sleep stands in
        shutil.copy(shutil.which('sleep'), self.node)
        self.state_file = self.home / 'rex-state.json'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('REX_', 'PI_'))}
        self.env.update(HOME=str(self.home), PATH=f'{fakebin}:{os.environ["PATH"]}',
                        FAKE_REX_STATE=str(self.state_file),
                        REX_SAFE_UPGRADE_RECONNECT_WAIT='3', REX_SAFE_UPGRADE_START_WAIT='3',
                        REX_SAFE_UPGRADE_PANE_WAIT='5')
        self.blocks = []
        self.pids = []
        self.records = self.home / '.local/state/rex-safe-upgrade/panes'
        self.records.mkdir(parents=True)
        self.addCleanup(self.kill_all)

    def kill_all(self):
        spawned = []
        if self.state_file.exists():
            spawned = json.loads(self.state_file.read_text()).get('spawned', [])
        for pid in self.pids + spawned:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def spawn(self, argv):
        pid = detached_pid(argv)
        self.pids.append(pid)
        return pid

    # -- panes --
    def pane(self, fg_name, pid, state='idle', app=None, cwd='/tmp', top=None):
        b = f'block:00000000-0000-0000-0000-{len(self.blocks) + 1:012d}'
        recs = [{'state': state, 'app': app or fg_name, 'owner': {'pid': pid}}] if state else []
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

    def spawn_in_terminal(self, argv):
        """argv as session leader of a new terminal, like a Rex pane's first program."""
        master, slave = os.openpty()
        p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, cwd='/tmp', env=self.env,
                             start_new_session=True, preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        os.close(slave)

        def stop():
            for c in children(p.pid):
                os.kill(c, signal.SIGKILL)
            p.kill()
            p.wait()
            os.close(master)
        self.addCleanup(stop)
        return p.pid

    def wrapper_pane(self, script='"$1" "$2"; exec sleep 60', tty=True, kids=1, owner='pi', state='idle',
                     record=True, agent_dir=None):
        """A pane started as `rex new -- sh -lc '... pi ...; exec $SHELL -l'`: Rex sees the
        wrapper shell as the pane's program, and Pi runs as its child."""
        argv = ['sh', '-lc', script, '_', str(self.fake_pi), str(self.node)]
        wrapper = self.spawn_in_terminal(argv) if tty else self.spawn(argv)
        self.assertTrue(wait_until(lambda: len(children(wrapper)) == kids and any(
            os.path.basename(os.readlink(f'/proc/{c}/exe')) == 'node' for c in children(wrapper))))
        pi = next(c for c in children(wrapper) if os.readlink(f'/proc/{c}/exe') == str(self.node))
        self.pids.append(pi)
        b = self.pane('dash', wrapper, state=state, app='pi')
        if owner == 'pi':
            self.blocks[-1]['program_status']['records'][0]['owner']['pid'] = pi
        if record:
            self.write_pi_record(b, pi, agent_dir=agent_dir)
        return b, wrapper, pi

    def pi_pane(self, record=True, session_file=True, agent_dir=None, record_pid=None,
                state='idle', has_messages=True, sfile=None, old_schema=False, ticks=None, version=2):
        pid = self.spawn(['bash', '-c', 'exec -a pi sleep 60'])
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
        pid = self.spawn([sys.executable, '-c', 'import time; time.sleep(60)', 'hermes', '--tui', '--resume', resume])
        return self.pane('python3.12', pid, app='hermes')

    def write_state(self, running='1.0', installed='2.0', reconnect=True, start_works=True,
                    fail_send=(), resume_wrong=(), resume_incomplete=(), on_second_ls=None, comes_back_as=None,
                    rexume='inactive', rexume_stop_fails=False, stop_hangs=False, restore_as=None):
        self.server_pid = self.spawn(['sleep', '60'])
        # Another session listed first, so finding a pane's session means searching.
        other = {'session_id': S[:-1] + '9', 'label': 'other', 'blocks': [], 'windows': []}
        self.state_file.write_text(json.dumps({
            'running': running, 'installed': installed, 'server_pid': self.server_pid,
            'instance': 'old', 'endpoint': ENDPOINT, 'reconnect': reconnect, 'start_works': start_works,
            'fail_send': list(fail_send), 'resume_wrong': list(resume_wrong),
            'resume_incomplete': list(resume_incomplete),
            'on_second_ls': on_second_ls or {}, 'ls_count': 0, 'spawned': [], 'calls': [],
            'comes_back_as': comes_back_as or installed,
            'rexume': rexume, 'rexume_stop_fails': rexume_stop_fails, 'systemctl_runtime_dirs': [],
            'stop_hangs': stop_hangs, 'restore_as': restore_as or {},
            'sessions': [other, {'session_id': S, 'label': 'work', 'blocks': self.blocks,
                                 'windows': [{'window_id': W, 'label': 'tab'}]}]}))

    def state(self):
        return json.loads(self.state_file.read_text())

    def tool(self, *args, env=None):
        return subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True,
                              env={**self.env, **(env or {})}, timeout=120)

    def run_tool(self, *extra):
        self.run_dir = self.home / 'run'
        r = self.tool('run', f'--run-dir={self.run_dir}', *extra)
        plan_file = self.run_dir / 'plan.json'
        plan = {p['block']: p for p in json.loads(plan_file.read_text())} if plan_file.exists() else {}
        return r, plan

    def server_alive(self):
        return Path(f'/proc/{self.server_pid}').exists()


class PlanTest(Base):
    def test_recorded_agents_and_idle_shells_are_safe(self):
        shell = self.pane('zsh', os.getpid(), state=None)
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
        self.pane('sleep', self.spawn(['sleep', '60']))
        self.assert_blocked("'sleep' is running and can't be resumed")
        r, _ = self.run_tool('--dry-run', '--allow-unresumable')
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_background_job_under_idle_shell_blocks(self):
        shell = self.spawn(['bash', '-c', 'sleep 60 & wait'])
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
        self.pane('sleep', self.spawn(['sleep', '60']))  # would block, but is never reached
        self.write_state(running='2.0', installed='2.0')
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 0)
        self.assertIn('nothing to do', r.stdout)
        r = self.tool()
        self.assertIn('(up to date)', r.stdout)
        self.assertIn('Nothing to do.', r.stdout)

    def test_plan_mode_reports_blockers(self):
        self.pi_pane()
        self.pane('sleep', self.spawn(['sleep', '60']))
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
        self.wrapper_pane(script='sleep 60 & "$1" "$2"; exec sleep 60', kids=2)
        self.assert_blocked('background processes would be stopped')

    def test_wrapper_child_outside_the_terminal_foreground_blocks(self):
        self.wrapper_pane(tty=False)
        self.assert_blocked('background processes would be stopped: node')

    def test_run_started_from_an_agent_pane_exempts_only_that_agent(self):
        # Rex preview.23 sets REX_BLOCK but no longer REX_SESSION.
        for env in ({}, {'REX_SESSION': S}):
            with self.subTest(env=env):
                self.blocks.clear()
                out, go = self.home / 'out.txt', self.home / 'go'
                go.unlink(missing_ok=True)
                # A busy "pi" (argv0 pi) that runs the plan from its pane.
                code = ('import os, subprocess, sys, time\n'
                        'while not os.path.exists(sys.argv[1]): time.sleep(0.05)\n'
                        'open(sys.argv[2], "w").write(subprocess.run(sys.argv[3:], capture_output=True, text=True).stdout)')
                b = f'block:00000000-0000-0000-0000-{len(self.blocks) + 1:012d}'
                caller_env = {**self.env, 'REX_BLOCK': b, **env}
                pid = detached_pid(['bash', '-c', 'exec -a pi "$@"', '_', sys.executable, '-c', code,
                                    str(go), str(out), sys.executable, str(TOOL)], env=caller_env)
                self.pids.append(pid)
                self.assertEqual(self.pane('node', pid, state='working', app='pi', top=os.getpid()), b)
                self.write_pi_record(b, pid)
                self.pi_pane(state='working')  # someone else's busy agent
                self.write_state()
                go.touch()
                self.assertTrue(wait_until(lambda: not Path(f'/proc/{pid}').exists(), 60))
                text = out.read_text()
                self.assertRegex(text, r'pi +working +resume via pane record \(this pane\)')
                self.assertEqual(text.count('(this pane)'), 1, text)
                self.assertEqual(text.count('pi is working'), 1, text)  # only the other one blocks

    def test_no_server(self):
        self.write_state(running=None)
        r = self.tool()
        self.assertEqual(r.returncode, 1)
        self.assertIn('No Rex server is running', r.stdout)


class RestartTest(Base):
    def setUp(self):
        super().setUp()
        self.shell = self.pane('zsh', os.getpid(), state=None)
        self.pi = self.pi_pane()
        self.fresh = self.pi_pane(session_file=False, has_messages=False)
        self.hermes = self.hermes_pane()
        # Rex's saved sessions for this endpoint, to be backed up after stop.
        sdir = self.home / '.local/state/rex/servers' / hashlib.sha256(ENDPOINT.encode()).hexdigest()
        sdir.mkdir(parents=True)
        (sdir / 'snapshot.db').write_text('saved')

    def log(self):
        return (self.run_dir / 'log.txt').read_text()

    def test_restart_resumes_every_agent_in_its_pane(self):
        self.write_state()
        r, plan = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(self.server_alive())
        self.assertIn('done: 3 agents resumed', self.log())
        self.assertEqual((self.run_dir / 'rex-state-backup/snapshot.db').read_text(), 'saved')
        sent = [c for c in self.state()['calls'] if c[:1] == ['send']]
        self.assertEqual(len(sent), 3)  # the idle shell gets nothing
        self.assertEqual(os.stat(self.run_dir).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(self.run_dir / 'log.txt').st_mode & 0o777, 0o600)

    def test_falls_back_to_starting_the_server(self):
        self.write_state(reconnect=False)
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn('starting the server here', self.log())
        self.assertIn(['server', 'start'], self.state()['calls'])

    def test_server_that_never_returns_leaves_manual_steps(self):
        self.write_state(reconnect=False, start_works=False)
        r, plan = self.run_tool()
        self.assertEqual(r.returncode, 4)
        log = self.log()
        self.assertIn('server did not come back', log)
        for b in (self.pi, self.fresh, self.hermes):
            self.assertIn(plan[b]['resume_cmd'], log)

    def test_one_failed_pane_does_not_stop_the_others(self):
        self.write_state(fail_send=[self.pi])
        r, plan = self.run_tool()
        self.assertEqual(r.returncode, 5)
        log = self.log()
        self.assertIn('verify work / tab: ok', log)
        self.assertIn(f"type in that pane: {plan[self.pi]['resume_cmd']}", log)
        self.assertEqual(log.count('type in that pane'), 1)

    def test_server_that_comes_back_on_the_old_version_is_reported(self):
        self.write_state(comes_back_as='1.0')
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 7, r.stdout)
        self.assertIn('the server was NOT upgraded', self.log())
        self.assertIn('verify work / tab: ok', self.log())  # agents still resumed

    def test_wrong_conversation_is_caught_by_verification(self):
        self.write_state(resume_wrong=[self.pi])
        r, plan = self.run_tool()
        self.assertEqual(r.returncode, 5)
        self.assertIn('NOT RUNNING the expected session', self.log())

    def test_record_that_does_not_prove_the_new_process_fails_verification(self):
        self.write_state(resume_incomplete=[self.pi])
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 5)
        self.assertIn('NOT RUNNING the expected session', self.log())

    def test_change_during_preflight_aborts_before_stop(self):
        self.write_state(on_second_ls={self.hermes: {'program_status': {'records': [{'state': 'working'}]}}})
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn('changed during preflight', r.stdout)
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
        self.assertIn('done: 4 agents resumed', self.log())
        self.assertIn('PI_CODING_AGENT_DIR=', plan[b]['resume_cmd'])

    def test_pane_restored_running_a_program_is_not_typed_into(self):
        # If Rex brought a pane back by re-running its `sh -c` command, the
        # shell Rex reports is not a prompt: typing there would reach that program.
        rerun = self.spawn(['sh', '-c', 'sleep 60; :'])
        self.write_state(restore_as={self.pi: {'name': 'dash', 'pid': rerun}})
        r, plan = self.run_tool()
        self.assertEqual(r.returncode, 5, r.stdout)
        self.assertIn('restored pane has no shell prompt', self.log())
        self.assertEqual(len([c for c in self.state()['calls'] if c[:1] == ['send']]), 2)

    # -- rexume: another daemon that reopens agents after a restart
    def systemctl_calls(self):
        return [c[1:] for c in self.state()['calls'] if c[0] == 'systemctl']

    def test_active_rexume_is_paused_for_the_restart(self):
        self.write_state(rexume='active')
        self.env.pop('XDG_RUNTIME_DIR', None)  # a default is still found
        r, _ = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.state()['calls']
        stop = calls.index(['systemctl', '--user', 'stop', 'rexume'])
        start = calls.index(['systemctl', '--user', 'start', 'rexume'])
        self.assertLess(stop, calls.index(['server', 'stop']))
        last_rex = max(i for i, c in enumerate(calls) if c[0] != 'systemctl')
        self.assertGreater(start, last_rex)  # after resume and verification
        self.assertEqual(self.state()['rexume'], 'active')
        self.assertEqual(set(self.state()['systemctl_runtime_dirs']), {f'/run/user/{os.getuid()}'})
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
        self.assert_rexume_restarted_after(4, reconnect=False, start_works=False)

    def test_rexume_is_started_again_when_a_pane_fails(self):
        self.assert_rexume_restarted_after(5, fail_send=[self.pi])

    def test_rexume_is_started_again_when_the_server_is_not_upgraded(self):
        self.assert_rexume_restarted_after(7, comes_back_as='1.0')

    def test_rexume_is_started_again_when_the_run_is_killed(self):
        self.write_state(rexume='active', stop_hangs=True)
        self.run_dir = self.home / 'run'
        p = subprocess.Popen([sys.executable, str(TOOL), 'run', f'--run-dir={self.run_dir}'],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=self.env)
        def stopping():
            try:
                return ['server', 'stop'] in self.state()['calls']
            except json.JSONDecodeError:  # caught mid-write
                return False
        self.assertTrue(wait_until(stopping, 30))
        p.send_signal(signal.SIGTERM)
        out = p.communicate(timeout=30)[0]
        self.assertNotEqual(p.returncode, 0, out)
        self.assertEqual(self.systemctl_calls()[-1], ['--user', 'start', 'rexume'], out)
        self.assertIn('started rexume again', self.log())


class InstallerTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('PI_')}
        self.env['HOME'] = str(self.home)
        self.tool = self.home / '.local/bin/rex-safe-upgrade'
        self.ext = self.home / '.pi/agent/extensions/rex-pane-session.ts'

    def setup(self, *args):
        return subprocess.run(['bash', str(SETUP), *args], capture_output=True, text=True, env=self.env)

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
