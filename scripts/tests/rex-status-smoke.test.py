#!/usr/bin/env python3
"""rex-status-smoke: runs the real script against a stateful fake `rex` and a
stub `pi`. No Rex, Pi runtime, model, or network."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/rex-status-smoke.py"

# The fake rex replays a scenario: `asking` is what program_status returns
# before the answer (after `delay` reads), `after` what it returns once the
# smoke sends Enter. Every call is logged.
FAKE_REX = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
WORKING = {"state": "working", "app": "pi", "effective_app": "pi", "owner": {"pid": 7}}
state = Path(os.environ["FAKE_REX_STATE"])
scenario = json.loads(Path(os.environ["FAKE_REX_SCENARIO"]).read_text())
s = json.loads(state.read_text()) if state.exists() else {"reads": 0, "answered": False}
args = sys.argv[1:]
with open(os.environ["FAKE_REX_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
def save():
    state.write_text(json.dumps(s))
if args[:2] == ["version", "--json"]:
    print(json.dumps({"rex_version": "0.0.0-test"}))
elif args[:1] == ["split"]:
    if scenario.get("split_fails"):
        print("no server", file=sys.stderr); sys.exit(1)
    print(json.dumps({"block_ids": ["block:smoke"]}))
elif args[:2] == ["block", "call"]:
    s["reads"] += 1; save()
    if s["answered"]:
        records = scenario["after"]
    else:
        records = scenario["asking"] if s["reads"] > scenario.get("delay", 0) else [WORKING]
    print(json.dumps({"records": records}))
elif args[:1] == ["send-key"]:
    s["answered"] = True; save()
elif args[:1] == ["capture"]:
    print(scenario.get("screen", ""))
elif args[:2] == ["block", "close"]:
    if scenario.get("close_fails"):
        print("block not found", file=sys.stderr); sys.exit(1)
else:
    print("unexpected: " + " ".join(args), file=sys.stderr); sys.exit(3)
'''

PI = {"app": "pi", "effective_app": "pi", "owner": {"pid": 7}}
BLOCKED = dict(PI, state="blocked", kind="question", msg="Waiting for your answer")
WORKING = dict(PI, state="working")
DONE = dict(PI, state="done")
IDLE = dict(PI, state="idle")
PROMPT_ECHO = "Call the ask_user_question tool exactly once with one question: header 'Color', " \
    "question 'Which color do you prefer?', options Red and Blue. Do nothing else."


class RexStatusSmokeTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, body in (("rex", FAKE_REX), ("pi", "#!/bin/sh\necho 1.6.1\n")):
            path = bin_dir / name
            path.write_text(body)
            path.chmod(0o755)
        agent = self.root / "agent/npm/node_modules/@juicesharp/rpiv-ask-user-question"
        agent.mkdir(parents=True)
        (agent / "package.json").write_text('{"version":"2.16.0"}')
        self.log = self.root / "log"
        self.scenario = self.root / "scenario.json"
        self.env = {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "HOME": str(self.root),
            "REX_BLOCK": "block:mine",
            "PI_CODING_AGENT_DIR": str(self.root / "agent"),
            "FAKE_REX_STATE": str(self.root / "state.json"),
            "FAKE_REX_SCENARIO": str(self.scenario),
            "FAKE_REX_LOG": str(self.log),
        }

    def run_smoke(self, scenario, *args, env=None):
        self.scenario.write_text(json.dumps(scenario))
        return subprocess.run([sys.executable, str(SCRIPT), "--timeout", "2", "--interval", "0.05", *args],
                              capture_output=True, text=True, env=env or self.env)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_pane_closed(self):
        self.assertEqual(self.calls()[-1], ["block", "close", "block:smoke"], "the test pane is always closed")

    def test_pass_when_blocked_then_cleared(self):
        r = self.run_smoke({"asking": [WORKING, dict(BLOCKED, id="x", app=None)], "after": [DONE], "delay": 3})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("rex 0.0.0-test, pi 1.6.1, rpiv-ask-user-question 2.16.0", r.stdout)
        self.assertIn("PASS", r.stdout)
        split = next(c for c in self.calls() if c[0] == "split")
        self.assertEqual(split[:3], ["split", "-b", "block:mine"])
        self.assertEqual(split[split.index("--") + 1:][:4], ["pi", "--no-session", "--model", "anthropic/claude-haiku-5-5:low"])
        self.assertIn(["send-key", "-b", "block:smoke", "enter"], self.calls())
        self.assert_pane_closed()

    def test_idle_after_answer_also_passes(self):
        r = self.run_smoke({"asking": [BLOCKED], "after": [IDLE]})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_records_not_from_the_launched_pi_never_pass(self):
        foreign = dict(BLOCKED, app="other", effective_app="other")
        r = self.run_smoke({"asking": [WORKING, foreign], "after": [DONE]})
        self.assertEqual(r.returncode, 1, "a blocked record from another program is not Pi's")
        self.assertNotIn(["send-key", "-b", "block:smoke", "enter"], self.calls())
        self.assert_pane_closed()

    def test_settled_record_from_another_process_fails(self):
        r = self.run_smoke({"asking": [BLOCKED], "after": [dict(IDLE, owner={"pid": 8})]})
        self.assertEqual(r.returncode, 1)
        self.assertIn("Pi didn't settle", r.stdout)

    def test_blocked_again_in_the_settled_snapshot_fails(self):
        r = self.run_smoke({"asking": [BLOCKED], "after": [DONE, dict(BLOCKED, id="again")]})
        self.assertEqual(r.returncode, 1)
        self.assertIn("still blocked", r.stdout)

    def test_echoed_prompt_with_an_error_is_not_the_regression(self):
        r = self.run_smoke({"asking": [dict(PI, state="error")], "after": [],
                            "screen": PROMPT_ECHO + "\nNo API key for provider"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("Pi never showed the question", r.stdout)
        self.assertNotIn("on screen but", r.stdout)

    def test_a_failed_close_fails_the_run(self):
        r = self.run_smoke({"asking": [BLOCKED], "after": [DONE], "close_fails": True})
        self.assertEqual(r.returncode, 1)
        self.assertIn("could not close the test pane block:smoke", r.stderr)

    def test_question_on_screen_but_not_blocked_is_the_regression(self):
        r = self.run_smoke({"asking": [WORKING], "after": [],
                            "screen": PROMPT_ECHO + "\n Color\n Which color do you prefer?\n ❯ 1. Red\n   2. Blue"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("the question is on screen but Rex doesn't show Pi as blocked", r.stdout)
        self.assertNotIn(["send-key", "-b", "block:smoke", "enter"], self.calls())
        self.assert_pane_closed()

    def test_pi_never_asking_shows_the_screen(self):
        r = self.run_smoke({"asking": [dict(PI, state="error")], "after": [], "screen": "No API key for provider"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("Pi never showed the question", r.stdout)
        self.assertIn("| No API key for provider", r.stdout)
        self.assert_pane_closed()

    def test_still_blocked_after_answer_fails(self):
        r = self.run_smoke({"asking": [BLOCKED], "after": [BLOCKED]})
        self.assertEqual(r.returncode, 1)
        self.assertIn("still blocked", r.stdout)
        self.assert_pane_closed()

    def test_not_settling_after_answer_fails(self):
        r = self.run_smoke({"asking": [BLOCKED], "after": [WORKING]})
        self.assertEqual(r.returncode, 1)
        self.assertIn("didn't settle", r.stdout)
        self.assert_pane_closed()

    def test_model_override_and_pi_default(self):
        self.run_smoke({"asking": [BLOCKED], "after": [DONE]}, "--model", "openai/test")
        split = next(c for c in self.calls() if c[0] == "split")
        self.assertEqual(split[split.index("--") + 1:][:4], ["pi", "--no-session", "--model", "openai/test"])
        self.log.unlink()
        (self.root / "state.json").unlink()
        self.run_smoke({"asking": [BLOCKED], "after": [DONE]}, "--model", "")
        split = next(c for c in self.calls() if c[0] == "split")
        self.assertEqual(split[split.index("--") + 1:][:2], ["pi", "--no-session"])
        self.assertNotIn("--model", split[split.index("--"):])

    def test_cannot_run_outside_rex_or_when_split_fails(self):
        env = dict(self.env)
        del env["REX_BLOCK"]
        r = self.run_smoke({"asking": [], "after": []}, env=env)
        self.assertEqual(r.returncode, 2)
        self.assertIn("not inside a Rex pane", r.stderr)
        self.assertEqual(self.calls(), [], "nothing reaches rex")
        r = self.run_smoke({"asking": [], "after": [], "split_fails": True})
        self.assertEqual(r.returncode, 2)
        self.assertIn("rex split failed: no server", r.stderr)


if __name__ == "__main__":
    unittest.main()
