#!/usr/bin/env python3
"""rex-safe-upgrade planning and installer tests.

The tool runs as a real subprocess against a scripted `rex` executable on PATH
(the CLI is its only seam to the server) and real processes for /proc
inspection. Nothing here contacts a live Rex server or restarts anything.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'scripts/rex-safe-upgrade.py'
SETUP = ROOT / 'scripts/setup-rex-safe-upgrade.sh'

FAKE_REX = textwrap.dedent('''\
    #!/usr/bin/env python3
    import json, os, sys
    fx = json.load(open(os.environ["FAKE_REX_FIXTURE"]))
    args = [a for a in sys.argv[1:] if not a.startswith("--autostart")]
    def out(v): print(json.dumps(v)); sys.exit(0)
    def opt(name): return args[args.index(name) + 1]
    sessions = {s["session_id"]: s for s in fx["sessions"]}
    if args[:1] == ["version"]: print("rex " + fx["installed"]); sys.exit(0)
    if args[:1] == ["whoami"]:
        if not fx.get("running"): sys.exit(1)
        out({"rex_version": fx["running"], "pid": 999999, "endpoint": "unix:///tmp/none.sock", "session_count": len(sessions)})
    if args[:1] == ["ls"]: out({"sessions": [{"session_id": k, "label": v["label"]} for k, v in sessions.items()]})
    if args[:2] == ["session", "inspect"]: out({"windows": sessions[args[2]]["windows"]})
    if args[:2] == ["block", "ls"]: out({"blocks": sessions[opt("-s")]["blocks"]})
    if args[:2] == ["block", "call"]:
        b = next(b for b in sessions[opt("-s")]["blocks"] if b["block_id"] == opt("-b"))
        out(b.get(args[-1], {}))
    if args[:1] == ["capture"]: print("screen"); sys.exit(0)
    sys.stderr.write("fake rex: unsupported %r\\n" % args); sys.exit(2)
''')

S = 'session:00000000-0000-0000-0000-000000000001'
W = 'window:00000000-0000-0000-0000-000000000002'


def block_id(n):
    return f'block:00000000-0000-0000-0000-{n:012d}'


class RexSafeUpgradeTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        fakebin = self.home / 'bin'
        fakebin.mkdir()
        (fakebin / 'rex').write_text(FAKE_REX)
        (fakebin / 'rex').chmod(0o755)
        self.fixture = self.home / 'fixture.json'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('REX_', 'PI_'))}
        self.env.update(HOME=str(self.home), PATH=f'{fakebin}:{os.environ["PATH"]}',
                        FAKE_REX_FIXTURE=str(self.fixture))
        self.blocks = []
        self.records = self.home / '.local/state/rex-safe-upgrade/panes'
        self.records.mkdir(parents=True)

    # -- fixture builders: real processes, scripted Rex view of them --
    def spawn(self, argv, exec_name=None):
        if exec_name:
            argv = ['bash', '-c', f'exec -a {exec_name} ' + ' '.join(argv)]
        p = subprocess.Popen(argv)
        self.addCleanup(p.wait)
        self.addCleanup(p.kill)
        return p.pid

    def pane(self, fg_name, pid, state='idle', app=None, cwd='/tmp'):
        b = block_id(len(self.blocks) + 1)
        self.blocks.append({
            'block_id': b, 'window_id': W, 'flavor': 'com.superlogical.terminal.shell',
            'process': {'foreground': {'name': fg_name, 'pid': pid, 'cwd': cwd}},
            'program_status': {'records': [{'state': state, 'app': app or fg_name}]},
        })
        return b

    def pi_pane(self, record=True, session_file=True, agent_dir=None, record_pid=None, state='idle'):
        pid = self.spawn(['sleep', '60'], exec_name='pi')
        b = self.pane('node', pid, state=state, app='pi')
        if record:
            sfile = None
            if session_file:
                sfile = self.home / f'{b[-4:]}.jsonl'
                sfile.write_text('{}\n')
            self.records.joinpath(b.removeprefix('block:') + '.json').write_text(json.dumps({
                'kind': 'pi', 'block': b, 'pid': record_pid or pid, 'cwd': '/tmp',
                'agentDir': agent_dir, 'sessionFile': str(sfile) if sfile else None}))
        return b

    def write_fixture(self, running='1.0', installed='2.0'):
        self.fixture.write_text(json.dumps({
            'running': running, 'installed': installed,
            'sessions': [{'session_id': S, 'label': 'work', 'blocks': self.blocks,
                          'windows': [{'window_id': W, 'label': 'tab'}]}]}))

    def tool(self, *args, env=None):
        return subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True,
                              env={**self.env, **(env or {})}, timeout=60)

    def dry_run_plan(self, *extra, env=None):
        run_dir = self.home / 'run'
        r = self.tool('run', '--detached', '--dry-run', f'--run-dir={run_dir}', *extra, env=env)
        plan = json.loads((run_dir / 'plan.json').read_text()) if (run_dir / 'plan.json').exists() else []
        return r, {p['block']: p for p in plan}

    # -- tests --
    def test_recorded_agents_and_idle_shells_are_safe(self):
        shell = self.pane('zsh', os.getpid())
        pi = self.pi_pane()
        fresh = self.pi_pane(session_file=False)
        profile = self.pi_pane(agent_dir=str(self.home / '.pi/agent-work'))
        hermes = self.pane('python3.12', self.spawn(
            [sys.executable, '-c', 'import time; time.sleep(60)', 'hermes', '--tui', '--resume', 'H-42']))
        self.write_fixture()
        r, plan = self.dry_run_plan()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('preflight ok', r.stdout)
        self.assertIsNone(plan[shell]['resume_cmd'])
        self.assertRegex(plan[pi]['resume_cmd'], r"^cd -- /tmp && pi --session \S+\.jsonl$")
        self.assertEqual(plan[fresh]['resume_cmd'], 'cd -- /tmp && pi')
        self.assertIn(f"PI_CODING_AGENT_DIR={self.home}/.pi/agent-work pi --session", plan[profile]['resume_cmd'])
        self.assertEqual(plan[hermes]['resume_cmd'], 'cd -- /tmp && hermes --tui --resume H-42')

    def test_unrecorded_pi_blocks_with_reload_hint(self):
        self.pi_pane(record=False)
        self.pi_pane(record_pid=1)  # record from an earlier pi process in this pane
        self.write_fixture()
        r, _ = self.dry_run_plan()
        self.assertEqual(r.returncode, 2)
        self.assertEqual(r.stdout.count('type /reload in that pane'), 2, r.stdout)
        self.assertIn('nothing changed', r.stdout)

    def test_unknown_program_blocks_unless_allowed(self):
        self.pane('sleep', self.spawn(['sleep', '60']))
        self.write_fixture()
        r, _ = self.dry_run_plan()
        self.assertEqual(r.returncode, 2)
        self.assertIn("'sleep' is running and can't be resumed", r.stdout)
        r, _ = self.dry_run_plan('--allow-unresumable')
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_busy_agent_blocks_except_the_invoking_pane(self):
        busy = self.pi_pane(state='working')
        self.write_fixture()
        r, _ = self.dry_run_plan()
        self.assertEqual(r.returncode, 2)
        self.assertIn('mid-task', r.stdout)
        r, _ = self.dry_run_plan(f'--self-block={busy}')
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_up_to_date_server_is_left_alone(self):
        self.pane('sleep', self.spawn(['sleep', '60']))  # would block, but is never reached
        self.write_fixture(running='2.0', installed='2.0')
        r, _ = self.dry_run_plan()
        self.assertEqual(r.returncode, 0)
        self.assertIn('nothing to do', r.stdout)
        r = self.tool()
        self.assertIn('(up to date)', r.stdout)
        self.assertIn('Nothing to do.', r.stdout)

    def test_plan_mode_reports_blockers(self):
        self.pi_pane()
        self.pane('sleep', self.spawn(['sleep', '60']))
        self.write_fixture()
        r = self.tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('(restart needed)', r.stdout)
        self.assertIn('resume via pane record', r.stdout)
        self.assertIn('Not safe right now', r.stdout)

    def test_no_server(self):
        self.write_fixture(running=None)
        r = self.tool()
        self.assertEqual(r.returncode, 1)
        self.assertIn('No Rex server is running', r.stdout)


class InstallerTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('PI_')}
        self.env['HOME'] = str(self.home)

    def setup(self, *args):
        return subprocess.run(['bash', str(SETUP), *args], capture_output=True, text=True, env=self.env)

    def test_apply_check_and_idempotence(self):
        self.assertNotEqual(self.setup('--check').returncode, 0)
        self.assertIn('Would install', self.setup().stdout)
        self.assertFalse((self.home / '.local/bin/rex-safe-upgrade').exists())
        for _ in range(2):
            r = self.setup('--apply')
            self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.setup('--check').returncode, 0)
        tool = self.home / '.local/bin/rex-safe-upgrade'
        self.assertTrue(os.access(tool, os.X_OK))
        self.assertTrue((self.home / '.pi/agent/extensions/rex-pane-session.ts').is_file())

    def test_updates_managed_copy_but_not_foreign_file(self):
        self.setup('--apply')
        tool = self.home / '.local/bin/rex-safe-upgrade'
        tool.write_text(tool.read_text() + '\n# older managed version\n')
        self.assertEqual(self.setup('--apply').returncode, 0)
        self.assertEqual(self.setup('--check').returncode, 0)
        ext = self.home / '.pi/agent/extensions/rex-pane-session.ts'
        ext.write_text('// hand-written\n')
        r = self.setup('--apply')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('not installed by dotfiles', r.stderr)
        self.assertEqual(ext.read_text(), '// hand-written\n')

    def test_respects_pi_agent_dir(self):
        self.env['PI_CODING_AGENT_DIR'] = str(self.home / 'work-agent')
        self.assertEqual(self.setup('--apply').returncode, 0)
        self.assertTrue((self.home / 'work-agent/extensions/rex-pane-session.ts').is_file())


if __name__ == '__main__':
    unittest.main()
