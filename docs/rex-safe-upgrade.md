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
  `PI_CODING_AGENT_DIR`). Whenever Pi starts, or switches conversation with
  `/new`, `/resume` or a fork, it writes
  `~/.local/state/rex-safe-upgrade/panes/<rex block id>.json` saying which
  session file is open in that Rex pane. Outside Rex it does nothing.

Pi processes that were already running when the extension was installed haven't
written a record yet. Type `/reload` in each of them, or restart them.

`--apply` only replaces files it installed earlier (they carry a
`Managed by dotfiles:` line). It refuses to overwrite anything else.

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

`run` is safe to start from inside a Rex pane, including from an agent. It hands
itself to a transient systemd unit (`rex-safe-upgrade-<time>`) so it keeps going
when the server stops and the pane closes. The pane comes back with its agent
resumed.

### What `run` does

1. Does nothing if the server already runs the installed version
   (`--even-if-current` overrides).
2. Checks every pane. It stops, changing nothing, if any of these is true:
   - an agent is mid-task (the pane that started the run is exempt);
   - a pane runs a program it can't bring back, such as a dev server or an
     editor;
   - a Pi pane has no current record (fix: `/reload` in that pane).
3. Saves each pane's screen and the plan, then runs `rex server stop`. The
   server saves sessions on stop. The tool then copies the saved-session
   database as a backup.
4. Waits up to 90 seconds for the Rex app to reconnect, which starts the new
   server through the login server. If that doesn't happen, it runs
   `rex server start` itself.
5. In each restored pane it types the resume command:
   - Pi: `cd -- <dir> && pi --session <session file>`, with
     `PI_CODING_AGENT_DIR=…` for non-default profiles. An empty session reopens
     a fresh `pi`.
   - Hermes: `cd -- <dir> && hermes --tui --resume <id>`, with the id taken from
     the running TUI.
6. Checks that each pane is running its agent again.

### Options

| Option | Effect |
|---|---|
| `--dry-run` | With `run`: check everything, change nothing |
| `--wait-idle MIN` | Wait up to MIN minutes for busy agents to finish before giving up |
| `--allow-unresumable` | Go ahead even though some programs can't be resumed. They stay stopped. |
| `--even-if-current` | Restart even if the server is already up to date |

## Logs and recovery

Every run writes to `~/.local/state/rex-safe-upgrade/runs/<time>/`. The last 8
runs are kept.

- `log.txt`: what happened. A pane that didn't resume shows the exact command
  to type in it.
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
- **Not automatic.** Nothing runs it on a schedule. A timer could run
  `rex-safe-upgrade run --wait-idle 60` nightly, but that would restart agents
  without anyone watching, so it is left as a manual step.

## Test

```bash
python3 scripts/tests/rex-safe-upgrade.test.py -v
```

The tests run the real tool against a scripted `rex` command on `PATH` and real
processes. They never contact a live Rex server.
