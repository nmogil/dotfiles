---
name: subagent-routing
description: "Pi-first subagent routing. Use before delegating work, choosing a worker model from the end user's task, spawning an agent pane, or handling model, quota, authentication, or usage-limit failures."
---
# Pi-first subagent routing

Route from the **original end-user goal**, not from an isolated subtask label.
Cost is not a selection factor.

## Procedure

1. Re-read the user's original request and classify its dominant work and risk.
2. Do not delegate a task that is faster and clearer to complete directly.
3. When delegation helps, use Pi first:
   - Prefer the in-process `Agent` tool from `pi-subagents`.
   - Use a separate Herdr pane running `pi` when the worker needs a visible terminal, a long-lived process, or the in-process tool is unavailable.
   - Never start Claude Code as the first attempt.
4. Give every worker the original goal, its bounded assignment, cwd, constraints, done conditions, and verification expected.
5. Select the model from the table below and state the choice in the Agent call or Pi command.
6. For consequential work, separate implementation and review across model families.
7. Report the runtime, model, and any fallback in the final result.

Completion criterion: every delegated task has an explicit Pi runtime, model, reason, and bounded verification target.

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

Claude Code is a worker fallback, not the delegator.

Trigger fallback automatically, without asking again, only when a selected
`anthropic/...` model cannot run through Pi because of:

- model unavailable or unsupported;
- Pi/provider authentication failure;
- quota, usage-limit, or rate-limit exhaustion;
- repeated provider transport failure that prevents the run from starting or completing.

Fallback sequence:

1. Preserve the exact assignment, cwd, constraints, and verification target.
2. Invoke Claude Code with the originally selected Claude model (strip the
   `anthropic/` provider prefix when needed).
3. If Claude Code does not support or cannot run that model, retry with
   `claude-opus-4-8` (or the `opus` alias if the full ID is unsupported).
4. Keep Pi as the parent/delegator and collect the Claude Code result back into
   the Pi session.
5. Disclose the triggering failure and the runtime/model actually used.

A weak but normally completed answer is not a runtime failure. Review it with a
different Pi model instead. If an OpenAI model fails, try another suitable Pi
model; do not route that failure to Claude Code unless the replacement task
itself requires a Claude model.
