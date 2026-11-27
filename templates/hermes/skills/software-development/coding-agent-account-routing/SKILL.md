---
name: coding-agent-account-routing
description: "Use before delegating or spawning Pi, Claude Code, or Codex. Selects and verifies the correct personal or configured work credential boundary."
---

# Coding-agent account routing

Account selection is a precondition to delegation. A model ID such as
`anthropic/claude-opus-5-5` identifies a model, not the account paying for or
receiving the request.

## Workstream mapping

- `~/.pi/agent` is the owner-authorized primary profile. It may be used for
  both personal work and work assigned to the locally configured second
  workstream, including implementation, subagents, testing, pushes, and PRs.
- `~/.pi/agent-<slug>` remains an optional dedicated profile for the configured
  second workstream; use it when explicitly requested or when a needed provider
  is available only there. Do not require a relaunch merely because a repository
  belongs to that workstream.
- The local workstream/profile name stays outside the public dotfiles repo. Use
  the current task context and local configuration to select it; do not infer an
  account from a model ID.
- Never move credentials between profiles or switch accounts with `/logout` and
  `/login` inside an active work session.
- Do not refuse configured-second-workstream work solely because Pi shows
  `[PERSONAL]` or the session lives under `~/.pi/agent/sessions`. That profile is
  explicitly authorized for the work. Other workstream boundaries remain strict.
- If a required provider/model exists only in the optional dedicated profile,
  use that profile or ask the user rather than moving credentials between
  profiles.

## Runtime rules

### Hermes `delegate_task`

Hermes-native children inherit the parent Hermes provider/model credentials
unless `delegation.*` explicitly overrides them. Pi profile paths do not apply.
Keep the child prompt in the parent's workstream and preserve the normal context
separation rules.

### In-process Pi `Agent`

Pi Subagents execute in the Delegator process and reuse its model registry and
agent directory. They therefore inherit the parent Pi profile automatically.
Do not log a child in separately. Before delegating, verify the parent footer
badge or `/session` path and report which authorized profile the child inherits.
Both the primary personal profile and the optional configured-work profile are
valid for the configured second workstream.

### Fresh Pi process

Never launch delegated work with bare `pi`. Set the profile explicitly:

```bash
# Personal (and owner-authorized primary profile)
PI_CODING_AGENT_DIR="$HOME/.pi/agent" pi --model <provider/model>

# Optional configured work profile
WORK_PROFILE_SLUG="${DOTFILES_PI_WORK_PROFILE_SLUG:-work}"
PI_CODING_AGENT_DIR="$HOME/.pi/agent-$WORK_PROFILE_SLUG" \
  pi --model <provider/model>
```

#### Rex visible Pi worker (default for visible panes)

Always launch delegated Rex Pi workers **interactively** (never with `-p` /
`--print`, which suppresses the TUI and leaves the pane blank until exit) so
the user can watch progress live and take over control of the session at any
time. Pass `-c "$TARGET_REPO"`, set `PI_CODING_AGENT_DIR` explicitly, and keep
an interactive shell alive if Pi exits:

```bash
ACTIVE_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
rex window new -s "$REX_BLOCK" "<label>" -c "$TARGET_REPO" --focus=false --json -- \
  sh -lc 'PI_CODING_AGENT_DIR="$1" pi --model "$2" --thinking "$3" "@$4"; exec "${SHELL:-/bin/zsh}" -l' \
  _ "$ACTIVE_AGENT_DIR" "<provider/model>" "<thinking>" "/tmp/<prompt>.md"
```

Because interactive Pi stays open after finishing its turn, do not block on
`rex wait` for completion. Instruct the worker to write a completion marker or
update its PR/branch, and poll that signal or capture the pane.

#### Herdr visible Pi worker (only when explicitly requested)

For Herdr, put the active profile and target cwd on a new shell pane, then start
Pi in that existing pane:

```bash
split_json=$(herdr pane split --current --direction right --cwd "$TARGET_REPO" \
  --env PI_CODING_AGENT_DIR="$AGENT_DIR" --no-focus)
agent_pane=$(printf '%s' "$split_json" | jq -r '.result.pane.pane_id')
herdr agent start <name> --kind pi --pane "$agent_pane" -- \
  --model <provider/model>
```

After spawn, verify the pane cwd and require the expected profile badge in its
Pi footer before submitting the assignment with `herdr agent prompt ... --wait`.

### Claude Code fallback

Claude Code uses its own credential store; selecting a Pi work profile does not
configure or select a matching Claude Code account. Generic bare-`claude`
examples in other skills do not authorize a work-profile launch. For work
assigned to the configured second profile, use Pi unless an account-explicit
Claude Code wrapper has been configured and its identity has been verified.
Otherwise stop and ask the user rather than silently using another account.

## Completion criterion

Every delegated coding-agent run reports its runtime, model, workstream, and
verified profile/account boundary. For the configured second workstream,
`~/.pi/agent` and `~/.pi/agent-<slug>` are both valid; ambiguity about which one
is active still blocks the spawn until it is verified.
