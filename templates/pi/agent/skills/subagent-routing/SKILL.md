---
name: subagent-routing
description: "Direct-first routing policy. Use before delegating, choosing a worker model, spawning an agent, or handling worker runtime failures."
---
# Direct-first subagent routing

Pi completes work directly by default. The presence of the `Agent` tool or a
matching role is never a reason to delegate. Honor any explicit instruction not
to delegate.

Delegate only when Noah explicitly requests it, or when at least one is true:

- materially independent work can run in parallel;
- large or risky context benefits from isolation;
- a genuine blocker requires specialist context;
- consequential work warrants independent cross-family review.

## Procedure

1. Route from the original end-user goal; cost is not a selection factor.
2. Verify the workstream and active credential profile before selecting a model
   or runtime. A model ID identifies a model, not a personal/work account.
3. Prefer in-process Pi `Agent`. Use a Herdr Pi pane only for a visible terminal,
   long-lived process, or unavailable in-process tooling. Do not start Claude
   Code first.
4. Bound the assignment with the original goal, exact cwd, constraints, done
   conditions, and verification. For every in-process Agent call, include the
   exact target cwd in the prompt and verify it matches the target repository.
5. Before any Herdr spawn, inspect panes/workspaces/tabs and the target repo.
   Select or create a project-specific tab in the correct workspace. Create its
   shell pane first with the exact `--cwd` and `PI_CODING_AGENT_DIR`, parse the
   returned pane ID, verify `cwd`, `foreground_cwd`, and the account badge, then
   use `agent start --kind pi --pane ...`. Submit normal work with
   `agent prompt ... --wait`. Never use an unrelated focused pane or bare `pi`.
6. Select the model below. Parallelize only independent assignments; isolate or
   serialize writers. Use cross-family review for consequential work.
7. Report delegation reason, runtime, model, account profile, fallback, and
   verification.

Completion criterion: each delegation passes the gate and has a bounded,
cwd-verified assignment plus explicit runtime, model, and account profile.

## Credential profile routing

- Personal work runs from `~/.pi/agent` and shows `[PERSONAL]`.
- Work assigned to the locally configured second profile runs from
  `~/.pi/agent-<slug>` and shows the uppercase slug.
  The local workstream/profile name stays outside this public repository.
- `anthropic/...` never identifies which Claude account is active.
- The account boundary outranks model preference. If a routed model is not
  available in the correct profile, choose a suitable model in that profile or
  ask the user; never switch profiles just to satisfy the model table.
- In-process Pi Subagents reuse the parent model registry and agent directory,
  so they inherit the parent profile automatically and need no separate login.
- If the parent profile is wrong, stop and relaunch with `pi-personal`,
  `pi-work`, or the configured `pi-<slug>` alias. Do not replace credentials
  mid-session with `/logout`/`/login`.
- A fresh Herdr Pi worker must receive the active profile explicitly:

```bash
ACTIVE_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
split_json=$(herdr pane split --current --direction right --cwd "$TARGET_REPO" \
  --env PI_CODING_AGENT_DIR="$ACTIVE_AGENT_DIR" --no-focus)
agent_pane=$(printf '%s' "$split_json" | jq -r '.result.pane.pane_id')
herdr agent start helper-pi --kind pi --pane "$agent_pane" -- \
  --model <provider/model> --thinking high
```

Verify the spawned footer badge before submitting work with
`herdr agent prompt helper-pi "$prompt" --wait --timeout <ms>`.

## Model routing

| Original user work | Pi model | Thinking | Use |
|---|---|---|---|
| Implementation, refactoring, tests, agentic coding | `openai-codex/gpt-5.6-sol` | `high` | Default engineering worker |
| Architecture or difficult debugging | `openai-codex/gpt-5.6-sol` | `high` or `max` | Deep causal and design work |
| Broad repository or very-large-context analysis | `anthropic/claude-opus-4-8` | `high` | Cross-file synthesis and long context |
| Critical independent review of Sol's work | `anthropic/claude-opus-4-8` | `high` | Cross-family review |
| Review of Claude-authored work | `openai-codex/gpt-5.6-sol` | `high` | Use `sol-reviewer`; preserve independence |
| Nuanced writing, product analysis, tone-sensitive docs | `anthropic/claude-sonnet-5` | `high` | Prose and product reasoning |
| Extreme uncertainty or unresolved Sol/Opus disagreement | `anthropic/claude-fable-5` | `high` | Third opinion only |
| Reproducible regression comparison | Available date-pinned snapshot | task-matched | Only when the user requires repeatability |

Do not select Luna, Terra, Mini, Haiku, or Spark merely to reduce cost. Use a
faster model only when the user explicitly prioritizes latency or a measured
workflow shows it performs better.

## Parallelism

Run agents in parallel only when their assignments are independent. Use the
smart join result before synthesizing. Never let two write-capable agents edit
the same working tree; use worktree isolation or serialize them.

## Claude Code fallback

Claude Code is a policy-authorized worker fallback, not the delegator. Its
credential store is independent from Pi profiles. Selecting a Pi work profile
does not select a matching Claude Code account.

Use fallback without asking again only when a selected `anthropic/...` model
cannot run through Pi because of:

- model unavailable or unsupported;
- Pi/provider authentication failure;
- quota, usage-limit, or rate-limit exhaustion;
- repeated provider transport failure that prevents the run from starting or completing.

Fallback sequence:

1. Preserve the exact assignment, cwd, constraints, and verification target.
2. For personal work, invoke Claude Code only after verifying its active
   account is the intended one.
3. For work assigned to the configured second profile, use only an
   account-explicit, identity-verified Claude Code wrapper. Without one,
   fallback is blocked: stay in that Pi profile or ask the user rather than
   launching bare `claude`.
4. Keep Pi as parent, preserve verification, and collect the result into Pi.
5. Disclose the triggering failure and actual runtime/model/account boundary.

A weak but normally completed answer is not a runtime failure. Review it with a
different Pi model instead. If an OpenAI model fails, try another suitable Pi
model; do not route that failure to Claude Code unless the replacement task
itself requires a Claude model.
