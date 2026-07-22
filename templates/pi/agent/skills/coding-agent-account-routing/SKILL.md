---
name: coding-agent-account-routing
description: "Use before delegating or spawning Pi, Claude Code, or Codex. Selects and verifies the correct personal or configured work credential boundary."
---

# Coding-agent account routing

Account selection is a precondition to delegation. A model ID such as
`anthropic/claude-opus-4-8` identifies a model, not the account paying for or
receiving the request.

## Workstream mapping

- Personal work uses `~/.pi/agent` and must show `[PERSONAL]` in Pi.
- Work assigned to the locally configured second profile uses
  `~/.pi/agent-<slug>` and must show the uppercase slug in Pi's footer.
- The local workstream/profile name stays outside the public dotfiles repo. Use
  the current task context and local configuration to select it; do not infer an
  account from a model ID.
- Never move credentials between profiles or switch accounts with `/logout` and
  `/login` inside an active work session.
- The account boundary outranks model preference. If the recommended model is
  unavailable in the correct profile, choose a suitable available model in that
  profile or ask the user; never borrow another profile to satisfy routing.

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
badge or `/session` path; if it is wrong, stop and relaunch the parent with
`pi-personal`, `pi-work`, or the configured `pi-<slug>` alias.

### Fresh Pi process

Never launch delegated work with bare `pi`. Set the profile explicitly:

```bash
# Personal
PI_CODING_AGENT_DIR="$HOME/.pi/agent" pi --model <provider/model>

# Configured work profile
WORK_PROFILE_SLUG="${DOTFILES_PI_WORK_PROFILE_SLUG:-work}"
PI_CODING_AGENT_DIR="$HOME/.pi/agent-$WORK_PROFILE_SLUG" \
  pi --model <provider/model>
```

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
verified profile/account boundary. A missing or ambiguous profile blocks the
spawn.
