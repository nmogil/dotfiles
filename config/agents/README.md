# Agent capability cleanup policy

This directory describes the intended skill and plugin surface for local AI
agents. It contains no credentials, provider endpoints, private MCP assignments,
or runtime state.

The cleanup is deliberately staged:

1. `./dot agents inventory` prints capability names only.
2. `./dot agents plan` reports differences without changing files.
3. `./dot agents check` validates these manifests.
4. A later, separately reviewed change may add backup/archive/apply behavior and
   switch `enforceAssignments` to `true`.

`~/.agents/skills` is treated as the cross-agent baseline because compatible
agents can discover it directly. Skills needed by only one runtime remain in
that runtime's own skill directory. Same-named skills with different contents
must be reviewed and merged; they must never be overwritten automatically.

The `local` skill lists are intended keepers owned by one agent. The `review`
lists are archive candidates, not deletion instructions. Plugin `review` lists
mean “disable and soak before removal.”

Live MCP names and assignments can reveal private integrations, so this public
repository tracks only `mcp-policy.example.json`. MCP credentials, auth state,
URLs, headers, commands, environment values, caches, and project-level config
remain local and untracked.
