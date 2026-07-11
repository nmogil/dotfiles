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
2. Prefer in-process Pi `Agent`. Use a Herdr Pi pane only for a visible terminal,
   long-lived process, or unavailable in-process tooling. Do not start Claude
   Code first.
3. Bound the assignment with the original goal, exact cwd, constraints, done
   conditions, and verification. For every in-process Agent call, include the
   exact target cwd in the prompt and verify it matches the target repository.
4. Before any Herdr spawn, inspect panes/workspaces/tabs and the target repo.
   Select or create a project-specific tab in the correct workspace; start with
   explicit `--workspace`, `--tab`, and `--cwd`; then verify the new pane's `cwd`
   and `foreground_cwd` before sending work. Never use an unrelated focused tab.
5. Select the model below. Parallelize only independent assignments; isolate or
   serialize writers. Use cross-family review for consequential work.
6. Report delegation reason, runtime, model, fallback, and verification.

Completion criterion: each delegation passes the gate and has a bounded,
cwd-verified assignment and explicit runtime/model.

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

Claude Code is a policy-authorized worker fallback, not the delegator. It is
available only **when tool access permits**; this policy cannot guarantee the
runtime is installed or callable.

Use fallback without asking again only when a selected `anthropic/...` model
cannot run through Pi because of:

- model unavailable or unsupported;
- Pi/provider authentication failure;
- quota, usage-limit, or rate-limit exhaustion;
- repeated provider transport failure that prevents the run from starting or completing.

Fallback sequence:

1. Preserve the exact assignment, cwd, constraints, and verification target.
2. When tool access permits, invoke Claude Code with the selected Claude model
   (strip `anthropic/` if needed), then Opus 4.8 only if that model is unsupported.
3. Keep Pi as parent, preserve verification, and collect the result into Pi.
4. Disclose the triggering failure and actual runtime/model.

A weak but normally completed answer is not a runtime failure. Review it with a
different Pi model instead. If an OpenAI model fails, try another suitable Pi
model; do not route that failure to Claude Code unless the replacement task
itself requires a Claude model.
