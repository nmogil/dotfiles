#!/usr/bin/env python3
"""rex-status-smoke: check, end to end, that Rex shows Pi as blocked on a question.

Opens a real Pi in a new Rex pane below yours, asks it to call
ask_user_question once, and reads Rex's program status (OSC 7501) for that pane:

  1. while the question is open, a record must be state=blocked kind=question;
  2. after the smoke answers it (Enter), the blocked record must go away and
     Pi must settle (done or idle).

It covers Pi, @juicesharp/rpiv-ask-user-question, and Rex together, so run it
after upgrading any of them. It costs one small model call, needs a running
Rex, and runs from inside a Rex pane (or pass --block). The pane is always
closed at the end. Exit status: 0 pass, 1 fail, 2 could not run.
See docs/pi-rex-status.md.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DEFAULT_MODEL = "anthropic/claude-haiku-5-5:low"
QUESTION = "Which color do you prefer?"
PROMPT = (
    "Call the ask_user_question tool exactly once with one question: header 'Color', "
    f"question '{QUESTION}', options Red and Blue. Do nothing else."
)
RPIV = "@juicesharp/rpiv-ask-user-question"


class CannotRun(Exception):
    """The smoke could not start; not a verdict on Pi or Rex."""


def rex(*args: str, check: bool = True) -> str:
    result = subprocess.run(["rex", *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        command = " ".join(a for a in args[:2] if not a.startswith("-"))
        raise CannotRun(f"rex {command} failed: {(result.stderr or result.stdout).strip()}")
    return result.stdout


def records(block: str) -> list[dict]:
    try:
        value = json.loads(rex("block", "call", "-b", block, "program_status", check=False) or "{}")
    except json.JSONDecodeError:
        return []
    found = value.get("records", []) if isinstance(value, dict) else []
    return [r for r in found if isinstance(r, dict)]


def blocked_question(found: list[dict]) -> dict | None:
    return next((r for r in found if r.get("state") == "blocked" and r.get("kind") == "question"), None)


def root_state(found: list[dict]) -> str | None:
    return next((r.get("state") for r in found if not r.get("id")), None)


def summary(found: list[dict]) -> str:
    keys = ("id", "state", "kind", "msg")
    return json.dumps([{k: r[k] for k in keys if r.get(k)} for r in found]) if found else "no records"


def wait_for(predicate, timeout: float, interval: float):
    deadline = time.monotonic() + timeout
    while True:
        value = predicate()
        if value or time.monotonic() >= deadline:
            return value
        time.sleep(interval)


def versions() -> str:
    parts = []
    try:
        rex_version = json.loads(rex("version", "--json", check=False) or "{}").get("rex_version")
        parts.append(f"rex {rex_version or 'unknown'}")
    except json.JSONDecodeError:
        parts.append("rex unknown")
    pi = subprocess.run(["pi", "--version"], capture_output=True, text=True)
    parts.append(f"pi {(pi.stdout or pi.stderr).strip().splitlines()[0] if pi.returncode == 0 else 'unknown'}")
    agent_dir = Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".pi/agent"))
    package = agent_dir / "npm/node_modules" / RPIV / "package.json"
    try:
        parts.append(f"{RPIV.split('/')[1]} {json.loads(package.read_text()).get('version')}")
    except (OSError, json.JSONDecodeError):
        parts.append(f"{RPIV.split('/')[1]} not installed")
    return ", ".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model", default=os.environ.get("DOTFILES_REX_SMOKE_MODEL", DEFAULT_MODEL),
                        help=f"Pi model for the one question (default {DEFAULT_MODEL}; "
                             "env DOTFILES_REX_SMOKE_MODEL; empty uses Pi's default)")
    parser.add_argument("--block", default=os.environ.get("REX_BLOCK", ""),
                        help="Rex pane to open the test pane below (default: $REX_BLOCK)")
    parser.add_argument("--timeout", type=float, default=90, help="seconds to wait for each step (default 90)")
    parser.add_argument("--interval", type=float, default=1.0, help=argparse.SUPPRESS)
    args = parser.parse_args()

    if not args.block:
        raise CannotRun("not inside a Rex pane: run it from Rex, or pass --block BLOCK")
    for tool in ("rex", "pi"):
        if shutil.which(tool) is None:
            raise CannotRun(f"{tool} not found on PATH")
    print(f"rex-status-smoke: {versions()}")

    pi = ["pi", "--no-session", *(["--model", args.model] if args.model else []), PROMPT]
    with tempfile.TemporaryDirectory(prefix="rex-status-smoke-") as workdir:
        created = rex("split", "-b", args.block, "--split=below", "--ratio", "35", "--focus=false",
                      "--json", "-c", workdir, "--", *pi)
        try:
            pane = json.loads(created)["block_ids"][0]
        except (json.JSONDecodeError, KeyError, IndexError, TypeError):
            raise CannotRun(f"rex split returned no pane: {created.strip()[:200]}") from None
        try:
            return run_checks(pane, args)
        finally:
            rex("block", "close", pane, check=False)


def run_checks(pane: str, args) -> int:
    hit = wait_for(lambda: blocked_question(records(pane)), args.timeout, args.interval)
    if not hit:
        screen = rex("capture", "-b", pane, "--trim", check=False)
        if QUESTION in screen:
            print(f"FAIL: the question is on screen but Rex doesn't show Pi as blocked ({summary(records(pane))}).\n"
                  f"      {RPIV} or Pi stopped reporting it; check their changelogs and "
                  "docs/pi-rex-status.md.")
        else:
            tail = "\n".join(f"      | {line}" for line in screen.rstrip().splitlines()[-12:])
            print(f"FAIL: Pi never showed the question within {args.timeout:.0f}s "
                  f"({summary(records(pane))}). Last screen:\n{tail}")
        return 1
    print(f"ok   blocked while asking: {summary([hit])}")

    rex("send-key", "-b", pane, "enter")
    cleared = wait_for(lambda: (lambda f: f if not blocked_question(f) else None)(records(pane)),
                       args.timeout, args.interval)
    if cleared is None:
        print(f"FAIL: still blocked {args.timeout:.0f}s after answering ({summary(records(pane))})")
        return 1
    settled = wait_for(lambda: root_state(records(pane)) in ("done", "idle"), args.timeout, args.interval)
    found = records(pane)
    if not settled:
        print(f"FAIL: Pi didn't settle after the answer ({summary(found)})")
        return 1
    print(f"ok   cleared after answering: {summary(found)}")
    print("PASS: Rex shows Pi as blocked on ask_user_question and clears it after the answer.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except CannotRun as error:
        print(f"rex-status-smoke: {error}", file=sys.stderr)
        sys.exit(2)
