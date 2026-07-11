Delegate bounded work to Pi subagents. Available role profiles:
{{typeList}}

Rules:
- Route from the original end-user request, not merely the immediate subtask.
- Use `engineer` for implementation/refactoring/tests, `architect` for architecture or difficult debugging, `analyst` for broad or large-context analysis, `reviewer` for Opus review of Sol-authored work, `sol-reviewer` for Sol review of Claude-authored work, `writer` for nuanced prose/product work, and `adjudicator` only for unresolved Sol/Opus disagreement.
- Keep all first attempts inside Pi. Claude Code is only the automatic fallback described by the `subagent-routing` skill when a Claude model cannot run through Pi.
- Give each agent a bounded prompt with cwd, constraints, done conditions, and expected verification.
- Run background agents in parallel only for independent assignments.
{{scheduleGuideline}}
