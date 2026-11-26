# Pi questions shown as blocked in Rex

When Pi asks you something with `ask_user_question`, Rex should show that pane
as **blocked** (waiting for you), not **working**. This page covers how that
works, what broke it once, and the two safeguards that keep it from breaking
again without anyone noticing.

## How it works

Pi reports its state to the terminal with Rex's Program Status Protocol
(OSC 7501): working, blocked, done, error, idle. Rex reads those reports into
the tab indicators, session picker, notifications, and
`rex block call -b BLOCK program_status`.

Pi reports `blocked` on its own for its built-in dialogs (`select`, `confirm`,
`input`). A `ctx.ui.custom()` component counts as blocked only when the
extension passes `blocked: { kind, message }`. `ask_user_question` comes from
the `@juicesharp/rpiv-ask-user-question` package, which renders its questionnaire
with `ctx.ui.custom()`, so whether Rex shows it as blocked depends on that
package.

## What broke

Up to 2.15.0, `rpiv-ask-user-question` didn't pass `blocked`, so a waiting
questionnaire showed as `working`. 2.16.0 passes
`blocked: { kind: "question" }`, and Rex shows `blocked / question / "Waiting
for your answer"`. Nothing failed loudly: the only sign was a pane that looked
busy while it waited for you.

## Safeguards

### 1. Package minimums in the Pi baseline

`PACKAGE_MINIMUMS` in `scripts/sync-pi-config.py` sets the lowest release the
personal Pi baseline may pin, with the reason:

| Package | Minimum | Why |
|---|---|---|
| `@juicesharp/rpiv-ask-user-question` | 2.16.0 | first release that reports a waiting questionnaire as blocked |

- `./dot pi config capture` refuses a live pin below the minimum (a prerelease
  of the minimum counts as below).
- `./dot pi config apply` and `check`, and so `./dot update`, refuse a
  baseline below it before writing anything.
- `check` already requires each machine's installed version to equal the
  baseline pin, so machines can't drift back either.

A package the baseline doesn't list isn't required; removing it is a
deliberate choice. Add a row when another package's older releases break
something you rely on.

This covers the personal profile only (`~/.pi/agent`). Other profiles, such as
`~/.pi/agent-work`, aren't managed by the baseline: upgrade them with
`PI_CODING_AGENT_DIR=<dir> pi install npm:<package>@<version>`.

### 2. Live check in Rex

Minimums stop going backwards. They can't tell whether a *newer* release of
the package, Pi, or Rex still behaves. The live check does:

```bash
./dot rex status-smoke              # from a Rex pane
./dot rex status-smoke --model ''   # use Pi's default model instead
```

It opens a real Pi in a new pane below yours and asks it to call
`ask_user_question` once. Then it reads Rex's program status for that pane:
a record must be `blocked` with `kind=question` while the question is open,
and after the check answers (Enter) the blocked record must go away and Pi
must settle (`done` or `idle`). It prints the Rex, Pi, and package versions,
always closes the pane, and exits 0 pass, 1 fail, 2 could not run.

```
rex-status-smoke: rex 0.1.0-preview.25, pi 1.6.1, rpiv-ask-user-question 2.16.0
ok   blocked while asking: [{"state": "blocked", "kind": "question", "msg": "Waiting for your answer"}]
ok   cleared after answering: [{"state": "done"}]
PASS: Rex shows Pi as blocked on ask_user_question and clears it after the answer.
```

On 2.15.0 it fails with the actual cause:

```
FAIL: the question is on screen but Rex doesn't show Pi as blocked ([{"state": "working"}]).
```

It costs one small model call (default `anthropic/claude-haiku-5-5:low`,
override with `--model` or `DOTFILES_REX_SMOKE_MODEL`) and needs a running
Rex, so it isn't run automatically. `./dot update` prints a reminder to run it
whenever it updates the Pi CLI or installs Pi packages. Run it yourself after
a Rex update.

## When the live check fails

1. Read the versions it printed and compare them with the last passing run.
2. "On screen but not blocked": the package or Pi stopped reporting it. Check
   whether the package still passes `blocked` to `ctx.ui.custom()`
   (`grep -n "blocked" ~/.pi/agent/npm/node_modules/@juicesharp/rpiv-ask-user-question/ask-user-question.ts`)
   and both changelogs. Pin the last good version in the baseline
   (`dotfiles-private/pi-config`) and raise the minimum if needed.
3. "Pi never showed the question": usually a model or auth problem; the
   output includes the pane's last screen.
4. Blocked while asking but not cleared: likely a Rex or Pi change; see the
   Rex changelog and `rex block call -b BLOCK program_status`.

## Test

```bash
python3 scripts/tests/pi-config.test.py        # package minimums
python3 scripts/tests/rex-status-smoke.test.py  # live check, against a fake rex
bash scripts/tests/update.test.sh               # ./dot update reminders
```
