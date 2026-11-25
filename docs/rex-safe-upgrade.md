# Upgrading the Rex server without losing agents

`rex-safe-upgrade` restarts a machine's Rex server onto the Rex version that is
installed, without losing an agent's work: it restarts only when every agent
is idle and every conversation can be reopened, and then lists the command
that reopens each agent in the pane it was running in.

## Why this exists

The Rex package updates itself (`apt` with unattended upgrades on the VPS), but
a running Rex server keeps the version it started with. To run the new version,
the server has to be stopped and started again.

A restart is not lossless by default:

| Survives a restart | Doesn't survive |
|---|---|
| Sessions, tabs, pane layout | Every program running in a pane |
| Each pane's working directory | Unsent text in an agent's input box |
| Scrollback | Background jobs and subagents an agent started |

Each pane comes back as a fresh shell. Agent conversations are saved on disk by
the agents themselves, so they can be reopened, but something has to know which
conversation was open in which pane, and the command that reopens it. That is
what this tool works out.

It doesn't type those commands. Rex has no way to report that a restored shell
is waiting at an empty prompt: a shell with nothing running under it may be
blocked in a builtin such as `read`, and typed text would go there. So the
commands are listed for you (or [rexume](#rexume)) to run.

## Install

On any Linux machine with systemd that runs its own Rex server:

```bash
./dot rex install --apply     # or --check / --dry-run
```

This installs two things:

- `~/.local/bin/rex-safe-upgrade`, the command.
- `~/.pi/agent/extensions/rex-pane-session.ts`, a Pi extension (respects
  `PI_CODING_AGENT_DIR`). Whenever Pi starts a session (including `/new`,
  `/resume`, forks and `/reload`) and after each agent run, it writes
  `~/.local/state/rex-safe-upgrade/panes/<rex block id>.json` with Pi's
  process id and start time, the session file open in that Rex pane, and
  whether the session has any messages yet. Before Pi switches conversation
  (`/new`, `/resume`, `/fork`, `/clone`) it deletes the record, so a failed
  write leaves no record rather than a wrong one. If it can't delete the
  record, it cancels the switch and says why. Outside Rex it does nothing.

Pi processes that were already running when the extension was installed or
updated haven't written a current record. Type `/reload` in each of them, or
restart them. The plan lists every pane that still needs it.

`--apply` only replaces files it installed earlier (they carry the same
`Managed by dotfiles: <path>` line as the repo copy). If either target is
something else, it changes nothing and says which file to review.

`./dot doctor` warns when the installed copies drift from the repo, and when the
running Rex server is older than the installed Rex.

## Use

```bash
rex-safe-upgrade          # show the plan; changes nothing
rex-safe-upgrade run      # restart, then list each agent's resume command
```

`./dot rex upgrade` and `./dot rex upgrade run` do the same from the repo.

The plan lists every pane and what will happen to it:

```
running server: 0.0.1794887753-g8b69ee
installed rex:  0.0.1795116584-ga086db   (restart needed)

  admin / Pennie PM            pi      idle     resume via pane record
  pennie-jeffery / PM          hermes  idle     resume via HERMES_TUI_RESUME
  admin / Window 3cf33762      pi      working  resume via pane record (this pane)
  admin / scratch              shell   -        nothing to resume

Safe to run:  rex-safe-upgrade run
```

When [rexume](#rexume) is running, the plan also says:

```
rexume is active and will be paused during the restart (started again afterwards).
```

`run` is safe to start from inside a Rex pane, including from an agent. The
agent that started it is found from `REX_BLOCK`. `REX_SESSION` is used as a
hint when set; Rex preview.23 no longer sets it, and if it is missing or wrong
the tool searches every session for that block, skipping sessions it can't
list. It checks everything first, then hands itself to a transient systemd unit
(`rex-safe-upgrade-<time>`, a user unit for non-root accounts) so it keeps going
when the server stops and the pane closes. The pane comes back as a shell;
the log lists its agent's resume command. Only one run can be in progress at
a time.

Every Rex call a run makes goes to one server: the one the first `rex whoami`
reaches, by the address it reports (`rex -S <endpoint>`), including through
the systemd handoff. So a run can't check the panes of one server and stop
another. The one exception is `rex version`, which asks the local CLI.

Only this machine's own Rex server is ever stopped. The first answer is
checked before anything is bound to its address (a remote server may report
a socket path that also exists here), and again right before the stop:

- its address is a unix socket (`unix:///path`; tcp, tailnet, https addresses
  and host labels are refused);
- the pid it reports is a `rex` process of this account, here, holding a
  listening stream socket at that path;
- the listener that actually answers at the path is that process: the tool
  connects and reads the peer's pid and uid (`SO_PEERCRED`), so a datagram
  socket or an unlinked listener that kept the name doesn't count.

That server's full identity (instance id, pid, address) is carried into the
run and through the systemd handoff, and every later answer must match it.
Otherwise the run stops with exit 3 and the plan says why.

### What `run` does

1. Does nothing if the server already runs the installed version
   (`--even-if-current` overrides). Stops, changing nothing, if it can't tell
   which version is installed (exit 2), or the server doesn't report its
   instance id, pid and endpoint or isn't verifiably this machine's own
   (exit 3).
2. Checks every pane. It stops, changing nothing, if any of these is true:
   - an agent is working or waiting for an answer, or hasn't reported its
     state (the agent process that started the run is exempt). This also
     holds for an agent that runs beside a background job, where the pane's
     program can't be attributed to it; such an agent must have reported
     its own state (a wrapper's record can't show it idle). Any status
     record of the running program that isn't idle counts, even next to an
     idle one; a record without a state, or a state Rex doesn't define,
     counts as unknown;
   - a pane runs a program it can't bring back, such as a dev server or an
     editor, or a shell has background jobs (including a `sh -c` wrapper
     with more than one program, see [Wrapper panes](#wrapper-panes));
   - a Pi pane has no record from its current process (fix: `/reload` in that
     pane), or its recorded session file has disappeared;
   - Hermes's session can't be determined;
   - two panes have the same conversation open;
   - Rex doesn't answer for a pane or a session, or a pane's foreground
     shell can't be read;
   - a pane's foreground shell runs a script or a command it can't attribute
     to one program (see [Wrapper panes](#wrapper-panes)).

   `--allow-unresumable` waives only the "can't be resumed" cases: unknown
   programs, background jobs, unrecorded Pi, a Pi session file that has
   disappeared, an unknown Hermes session, and shells running scripts or
   commands. Those programs are stopped and not resumed. Busy agents, agents
   whose state is unknown, unreadable panes, sessions or shells, and
   duplicate conversations always block, whatever else the pane shows.
3. Saves each pane's screen and the plan.
4. Asks whether rexume runs. If it can't tell (no reachable user manager, a
   timeout, an unexpected answer), it stops with exit 8 and changes nothing.
   If rexume is active it pauses it (`systemctl --user stop rexume`); if that
   fails, exit 8 and nothing changed.
5. After the pause, which can take minutes, and immediately before stopping,
   it runs every check from step 2 again and confirms the server is still the
   same instance (exit 2 or 3, nothing changed, if not). Then it asks the
   server at its endpoint once more, verifies it as local again, and runs
   `rex -S <endpoint> server stop`
   (the server saves sessions on stop), and copies the saved-session database
   as a backup. `rex server stop` can't name an instance, only an address: if
   another server replaced this one at the same address between those last two
   commands, that one would be stopped. `rex` and `systemctl` are resolved
   once per run, to canonical absolute paths from absolute `PATH` entries,
   and always run from there.
6. Waits up to 90 seconds for the Rex app to reconnect, which starts the new
   server through the login server. It doesn't start a server itself:
   `rex server start` can't be told which address to serve, and a server it
   can't verify is no recovery. If none comes back, it exits 4 with the steps
   to take.
7. Checks that a new server answers at the same address, with a complete
   identity (exit 4 otherwise), and whether it runs the installed version
   (exit 7 if not).
8. Lists the command that resumes each agent, in the log and on the run's
   output. Nothing is typed (see [Why this exists](#why-this-exists)). Each
   line names the pane by its labels and by its session and block IDs, since
   labels repeat:

   ```
   work / tab [session session:…01, block block:…02]: cd -- /srv/app && pi --session …
   ```

   `rex block ls -s <session>` lists a session's blocks, and
   `rex focus -s <session> <block>` takes you to one.
   - Pi: `cd -- <dir> && pi --session <session file>`, with
     `PI_CODING_AGENT_DIR=…` for non-default profiles. A session with no
     messages yet reopens a fresh `pi`.
   - Hermes: `cd -- <dir> && hermes --tui --resume <id>`. The id comes from
     the TUI's active-session file, which follows `/new` and `/resume`, then
     from how it was launched.
9. Starts rexume again if it tried to pause it. This happens on every way
   out once the stop was attempted: success, every failure exit, errors, and
   the run being stopped by SIGTERM, SIGHUP or SIGINT. Recovery is armed
   before `systemctl stop` runs; `systemctl` runs in its own session, so a
   signal to the run's process group can't kill it; the systemd unit uses
   `KillMode=mixed` with `TimeoutStopSec=300`, so stopping the unit signals
   only the run; and further signals are ignored until rexume
   is started again. If it can't be started, the run exits 8 (unless it
   already failed with another code) and the log says how to start it.

### Wrapper panes

Panes started by an orchestrator as

```bash
rex new -- sh -lc 'PI_CODING_AGENT_DIR="$1" pi --model "$2" --thinking "$3" "@$4"; exec "${SHELL:-/bin/zsh}" -l' _ ...
```

show up in Rex with the `sh -lc` shell as their program, and Pi as its child.
The tool treats the child as the pane's program when all of these hold:

- the foreground shell was started with a command (`-c`, `-lc`,
  `-O extglob -c`, fish `--command`); a script, or any form it doesn't
  recognize, blocks the run instead;
- it has exactly one child (prompt helpers aside);
- that child shares the shell's session and terminal and is in the
  terminal's foreground process group.

Pi there is then checked, and its resume command listed, exactly like Pi
started from a prompt
(same pane record, `/reload` hint, busy check, `PI_CODING_AGENT_DIR` from the
record). Rex may report the busy state under the wrapper's pid rather than
Pi's (snapshot.2513 does). A status owned by the wrapper counts if it was
updated after this Pi started and names Pi; Pi's own records and those count
together, and any that isn't idle wins. With none, Pi's state is unknown,
which always blocks. A child that is itself a shell counts as idle only if it
was started as an interactive or login shell. Any other process under the wrapper still blocks
as a background process, and a shell whose process data can't be read blocks
as unreadable.

The restored pane is a fresh login shell, so the listed command is the usual
`pi --session <file>`. The `--model`/`--thinking` flags from the original
command are not repeated: Pi restores the model and thinking level recorded in
the session.

### rexume

[rexume](https://github.com/Entwining/rexume) is a daemon that, after every
Rex server restart, types a command into each restored shell to reopen Pi,
Claude Code, Codex, omp and OpenCode conversations. `rex-safe-upgrade` owns the
restart itself, so rexume is paused while it happens:

- If `systemctl --user is-active rexume` says it's active when the restart
  phase begins, the run stops it, checks everything again, and runs
  `rex server stop`; it starts rexume again once the new server is checked,
  or on any other way out (see step 9). Both are logged.
- Only a definite answer counts: "active" goes ahead with the pause;
  "inactive" or "not installed" from the user manager changes nothing. Any
  other outcome (no user manager reachable, a timeout, an odd answer) aborts
  with exit 8 before touching Rex.
- If stopping it fails, the run aborts with exit 8 before touching the server,
  and runs `systemctl --user start rexume` so it is left running.
- The calls happen in the process that restarts the server. Inside Rex that is
  the transient `rex-safe-upgrade-<time>` unit; for root it's a system unit.
  `systemctl --user` gets this account's own user manager: `XDG_RUNTIME_DIR`
  (or `/run/user/<uid>` when unset) must be an absolute directory owned by
  this account, and an inherited `DBUS_SESSION_BUS_ADDRESS` is dropped.
  Otherwise the state counts as unknown.

Once rexume runs again it may reopen conversations in the restored shells
itself, by typing into them, which this tool doesn't do. rexume skips panes
where a program already runs, so check each pane before typing a command from
the log: if its agent is already back, don't type it.

Only the Linux systemd unit is handled. On macOS rexume runs as the
LaunchAgent `io.github.entwining.rexume`, but this tool doesn't run on macOS.

### Options

| Option | Effect |
|---|---|
| `--dry-run` | With `run`: check everything, change nothing |
| `--wait-idle MIN` | Wait up to MIN minutes for busy agents to finish before giving up |
| `--allow-unresumable` | Go ahead even though some programs can't be resumed. They stay stopped. |
| `--even-if-current` | Restart even if the server is already up to date |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Restarted onto the installed version (the log lists each agent's resume command), or nothing to do |
| 1 | No Rex server running |
| 2 | Not safe right now (including: installed version unknown, panes changed before the stop); nothing changed |
| 3 | Server identity incomplete, changed before the stop, or not verifiably this machine's own (nothing changed); or the old server didn't stop |
| 4 | No new server with a complete identity came back at the same address; the log lists the steps and each pane's resume command |
| 6 | Another run is in progress; nothing changed |
| 7 | Restarted, but the server that came back isn't the installed version; the log lists the resume commands |
| 8 | Couldn't tell whether rexume runs, or couldn't pause it (nothing changed); or it couldn't be started again after an otherwise successful run |

## Logs and recovery

Every run writes to `~/.local/state/rex-safe-upgrade/runs/<time>/`, readable
only by you. The last 8 runs are kept.

- `log.txt`: what happened. After the stop, it lists the exact command to type
  in each pane whose agent needs reopening.
- `plan.json`: every pane with its resume command.
- `<block>.screen.txt`: each pane's screen just before the restart.
- `rex-state-backup/`: the Rex saved-session database as written at stop.

While a run is going, `journalctl -u 'rex-safe-upgrade-*'` shows it too.

If the server doesn't come back, open the Rex app, or run `rex server start`
and check that `rex whoami` reports the same address as before. Then type the
commands from the log (or `plan.json`) into the panes, finding each by its
block ID.

## Limits

- **Linux with systemd only.** On macOS the Rex app runs the server, and you
  update it like any other app.
- **Local server only.** It inspects this machine's processes, so install and
  run it on each machine. `rex -S <host>` can't upgrade another machine.
- **Personal or login-server account servers only.** The shared `rex.service`
  setup (one server run as the `rex` account) restarts with the package and
  isn't handled here.
- **Agents:** Pi and Hermes TUI. Claude Code, Codex and other programs count as
  unresumable for now.
- **Child processes of an agent** (MCP servers, subagents) stop with it. Pi
  and Hermes start their MCP servers again on resume. A subagent that is
  still running usually means the agent is working, which blocks the run.
- **Not a security boundary.** It runs with your own permissions and trusts
  your own files: the Pi records, and the identity of the agent that started a
  run. Anyone who can tamper with those can already run `rex server stop`.
- **Resuming is by hand.** Rex reports no prompt state for a shell, so the
  tool types nothing; you (or rexume) run the listed commands. Panes that ran
  an agent directly (`rex run -- pi`) may not come back with a shell prompt at
  all.
- **Not automatic.** Nothing runs it on a schedule. A timer could run
  `rex-safe-upgrade run --wait-idle 60` nightly, but that would restart agents
  without anyone watching, so it is left as a manual step.

## Test

```bash
python3 scripts/tests/rex-safe-upgrade.test.py -v   # anywhere: installer + parser tests
node scripts/tests/rex-pane-session.test.mjs
```

The tests run the real tool against a stateful fake `rex` and a fake
`systemctl`, and real processes: planning and every blocker (including which
ones `--allow-unresumable` can't waive, reused pids and forged
self-exemptions), Pi behind a real `-lc` wrapper in a real terminal, shell
command lines that fail closed, the run's own pane found from `REX_BLOCK` with
a missing or stale `REX_SESSION`, status that can't be trusted, a full restart
that types nothing and lists every resume command, every Rex call going to
the selected server (also when the default route changes mid-run), the last
checks before the stop, the app not reconnecting, the server never returning,
returning incomplete or on the old version, a concurrent run, rexume paused
and started again on every way out (including signals during its stop and
group signals during recovery) and rexume whose state is unknown, and the
installer.
The second drives the Pi extension's handlers against real files. Neither
starts Pi.

### Where the integration tests may run

On 2026-11-25 a test run on the VPS stopped its real Rex server: a test failed
while its `run` was still going, cleanup deleted the fake `rex`, and the run's
next `rex server stop` found `/usr/bin/rex` on `PATH`.

The boundary is the machine, not the tests' `PATH`: the Linux integration
tests run only in an isolated sandbox. They skip unless
`REX_SAFE_UPGRADE_TEST_SANDBOX=1` is set and there is no `rex` binary, no Rex
runtime directory under `/run/user` and no user systemd bus. Set the variable
only in a throwaway container or a CI runner. With
`REX_SAFE_UPGRADE_TEST_REQUIRE_SANDBOX=1` a missing sandbox fails the run
instead of skipping it; CI runs them that way, in a container:

```bash
docker run --rm --init --network none -v "$PWD:/w:ro" -w /w \
  -e REX_SAFE_UPGRADE_TEST_SANDBOX=1 -e REX_SAFE_UPGRADE_TEST_REQUIRE_SANDBOX=1 \
  python@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b \
  python3 -B scripts/tests/rex-safe-upgrade.test.py -v   # python:3.12-slim, as in CI
```

Never set it on a machine that runs Rex. Inside the sandbox the tests add
defense in depth, none of which is the boundary:

- Every subprocess gets a minimal environment built from scratch (no
  `BASH_ENV`, `ENV` or host variables) and absolute helper paths from
  `/usr/bin:/bin`; bash runs with `--noprofile --norc`, and no fixture runs a
  login shell.
- `PATH` holds only the fakes, then tripwire copies of `rex`, `systemctl` and
  `systemd-run` that record any call; every test fails if one fired.
- `REX_SAFE_UPGRADE_TEST_ROOT` puts the tool in test mode: it exits 2 without
  doing anything unless that directory carries the fixture marker, `rex` and
  `systemctl` resolve to its `bin/` (itself inside the root), and `HOME` and
  `XDG_RUNTIME_DIR` are inside it with no session bus set; it never starts a
  systemd unit.
- The test process is a child subreaper: everything a test starts, and every
  orphan those leave, stays its child, is reaped as it exits, and is killed
  through pidfds before the test's files are removed. Teardown repeats until
  nothing is left and never blocks past its deadline. No fixture uses
  `preexec_fn`; a terminal is attached by a small launcher that execs.
