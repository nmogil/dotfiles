# Upgrading the Rex server without losing agents

`rex-safe-upgrade` restarts a machine's Rex server onto the Rex version that is
installed, then resumes every coding agent in the pane it was running in.

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
conversation was open in which pane and type the command to reopen it. That is
what this tool does.

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
rex-safe-upgrade run      # restart and resume
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
agent that started it is found from `REX_BLOCK` (and `REX_SESSION` when set;
Rex preview.23 no longer sets it, so the tool looks up the session holding that
block). It checks everything first, then hands itself to a transient systemd unit
(`rex-safe-upgrade-<time>`, a user unit for non-root accounts) so it keeps going
when the server stops and the pane closes. The pane comes back with its agent
resumed. Only one run can be in progress at a time.

### What `run` does

1. Does nothing if the server already runs the installed version
   (`--even-if-current` overrides).
2. Checks every pane. It stops, changing nothing, if any of these is true:
   - an agent is working or waiting for an answer, or hasn't reported its
     state (the agent process that started the run is exempt);
   - a pane runs a program it can't bring back, such as a dev server or an
     editor, or a shell has background jobs (including a `sh -c` wrapper
     with more than one program, see [Wrapper panes](#wrapper-panes));
   - a Pi pane has no record from its current process (fix: `/reload` in that
     pane), or its recorded session file has disappeared;
   - Hermes's session can't be determined;
   - two panes have the same conversation open;
   - Rex doesn't answer for a pane.

   `--allow-unresumable` waives only the "can't be resumed" cases: unknown
   programs, background jobs, unrecorded Pi, a Pi session file that has
   disappeared, and an unknown Hermes session. Those programs are stopped and
   not resumed. Busy agents, agents that haven't reported their state,
   unreadable panes and duplicate conversations always block.
3. Saves each pane's screen and the plan. Right before stopping, it checks the
   server and every pane again; if anything changed, it stops without changing
   anything.
4. If rexume is active, pauses it (`systemctl --user stop rexume`); if that
   fails, it stops with exit 8 and changes nothing. Then it runs
   `rex server stop` (the server saves sessions on stop) and copies the
   saved-session database as a backup.
5. Waits up to 90 seconds for the Rex app to reconnect, which starts the new
   server through the login server. If that doesn't happen, it runs
   `rex server start` itself.
6. In each restored pane that shows a shell prompt it types the resume
   command. A pane whose shell is running a command (`sh -c ...`) is not a
   prompt, so nothing is typed there and the pane is reported instead:
   - Pi: `cd -- <dir> && pi --session <session file>`, with
     `PI_CODING_AGENT_DIR=…` for non-default profiles. A session with no
     messages yet reopens a fresh `pi`.
   - Hermes: `cd -- <dir> && hermes --tui --resume <id>`. The id comes from
     the TUI's active-session file, which follows `/new` and `/resume`, then
     from how it was launched.
   A pane that fails doesn't stop the others.
7. Checks that each pane runs the same conversation again: Pi's new record
   must name the same session file, and Hermes must have been resumed with the
   same id. It also checks that the server that came back is a new instance
   running the installed version.
8. Starts rexume again if it paused it. This happens on every way out after
   the pause: success, exits 3, 4, 5 and 7, errors, and the run being stopped
   (SIGTERM/SIGHUP).

### Wrapper panes

Panes started by an orchestrator as

```bash
rex new -- sh -lc 'PI_CODING_AGENT_DIR="$1" pi --model "$2" --thinking "$3" "@$4"; exec "${SHELL:-/bin/zsh}" -l' _ ...
```

show up in Rex with the `sh -lc` shell as their program, and Pi as its child.
When the pane's foreground program is a shell running a `-c` command, it has
exactly one child (prompt helpers aside), and that child is in the terminal's
foreground process group, the tool treats the child as the pane's program:
Pi there is checked and resumed exactly like Pi started from a prompt (same
pane record, `/reload` hint, busy check, `PI_CODING_AGENT_DIR` from the
record). Rex may report the busy state under the wrapper's pid rather than
Pi's (snapshot.2513 does); either counts. Any other process under the wrapper
still blocks as a background process.

The restored pane is a fresh login shell, so the resume command is the usual
`pi --session <file>`. The `--model`/`--thinking` flags from the original
command are not repeated: Pi restores the model and thinking level recorded in
the session.

### rexume

[rexume](https://github.com/Entwining/rexume) is a daemon that, after every
Rex server restart, types a command into each restored shell to reopen Pi,
Claude Code, Codex, omp and OpenCode conversations. During a `run` both would
type into the same panes, so `rex-safe-upgrade` owns planned upgrades:

- If `systemctl --user is-active rexume` says it's active when the restart
  phase begins, the run stops it right before `rex server stop` and starts it
  again once resume and verification are over, or on any other way out
  (see step 8). Both are logged.
- If stopping it fails, the run aborts with exit 8 before touching the server,
  and runs `systemctl --user start rexume` so it is left running.
- If rexume isn't installed or isn't running, nothing changes.
- The calls happen in the process that restarts the server. Inside Rex that is
  the transient `rex-safe-upgrade-<time>` unit; for root it's a system unit,
  so the tool passes `XDG_RUNTIME_DIR` (default `/run/user/<uid>`) to reach the
  account's user manager.

rexume skips panes where a program is already running, so panes this tool
resumed are left alone when it starts again. A pane this tool failed to resume
(exit 4 or 5) is still a bare shell, so rexume may reopen a conversation there
once it is back. Check those panes before typing the commands from the log.

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
| 0 | Done, or nothing to do |
| 1 | No Rex server running |
| 2 | Not safe right now; nothing changed |
| 3 | Server changed during preflight (nothing changed), or the old server didn't stop |
| 4 | Server didn't come back; the log lists the commands to resume each pane |
| 5 | Some panes didn't resume; the log lists their commands |
| 6 | Another run is in progress; nothing changed |
| 7 | Agents resumed, but the server that came back isn't the installed version |
| 8 | rexume is running and couldn't be paused; nothing changed |

## Logs and recovery

Every run writes to `~/.local/state/rex-safe-upgrade/runs/<time>/`, readable
only by you. The last 8 runs are kept.

- `log.txt`: what happened. If anything goes wrong after the stop, the log
  ends with the exact command to type in each pane that still needs it.
- `plan.json`: every pane with its resume command.
- `<block>.screen.txt`: each pane's screen just before the restart.
- `rex-state-backup/`: the Rex saved-session database as written at stop.

While a run is going, `journalctl -u 'rex-safe-upgrade-*'` shows it too.

If the server doesn't come back, start it with `rex server start`, or open the
Rex app, then type the commands from `plan.json` into the panes.

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
- **Panes that ran an agent directly** (`rex run -- pi`) rather than from a
  shell may not come back with a shell prompt. If one comes back running its
  original command, or anything other than a prompt, nothing is typed into it
  and the log shows the command to run by hand.
- **Not automatic.** Nothing runs it on a schedule. A timer could run
  `rex-safe-upgrade run --wait-idle 60` nightly, but that would restart agents
  without anyone watching, so it is left as a manual step.

## Test

```bash
python3 scripts/tests/rex-safe-upgrade.test.py -v
node scripts/tests/rex-pane-session.test.mjs
```

The tests run the real tool against a stateful fake `rex` and a fake
`systemctl` on `PATH`, and real processes: planning and every blocker
(including which ones `--allow-unresumable` can't waive, reused pids and forged
self-exemptions), Pi behind a real `sh -lc` wrapper in a real terminal, the
run's own pane found from `REX_BLOCK` with and without `REX_SESSION`, a full
restart with resume and verification, the app not reconnecting, the server
never returning, the server coming back on the old version, a pane that fails,
a pane restored running a command, the wrong conversation coming back, a
change during preflight, a concurrent run, rexume paused and started again on
success, failure and SIGTERM (and a stop that fails), and the installer. The second drives the Pi extension's
handlers against real files, including a record that can't be removed. They
never contact a live Rex server or start Pi.
