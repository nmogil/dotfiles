# Pi agent setup (opt-in)

An opt-in installer for a [Pi coding agent](https://github.com/mariozechner/pi)
workspace. It is **not** applied by `setup.sh` / `setup-linux.sh`; you install
it deliberately.

The scaffold content itself is **not tracked in this repo**: it was adapted
from [dmmulroy/.dotfiles](https://github.com/dmmulroy/.dotfiles), which grants
no license, so it lives outside the public tree — see
[`licensing.md`](licensing.md). Point `DOTFILES_PI_SCAFFOLD_DIR` in
`~/.config/dotfiles/local.env` at a local checkout of your scaffold (for the
author, a private companion repo); a fork-local `templates/pi/` is used as the
fallback when the variable is unset.

## TL;DR

```bash
./dot pi doctor               # read-only checks
./dot pi scaffold --dry-run   # preview copy into ~/.pi
./dot pi scaffold --apply     # copy scaffold (skips existing; --force backs up)
./dot pi profiles --apply     # prepare separate personal/work profiles
./dot pi subagents --dry-run  # preview pinned Pi subagent package installation
./dot pi subagents --apply    # install the pinned Codex subagent package
./dot pi install              # install pinned npm Pi; migrates Vite+ Pi after confirmation
```

The scaffold's own README covers the post-copy manual steps
(`npm install`, copy the `*.example.json` files, `pi /reload`).

The example JSON field names are intentionally conservative and may need to be
adjusted for the Pi version you install. Treat them as a starting template, not
an authoritative Pi schema.

## What was adapted (safe, generic)

| File | Notes |
|------|-------|
| `.gitignore` | Ignores `node_modules`, runtime `settings.json`/`mcp.json`, auth/session state |
| `README.md` | Rewritten for this repo; opt-in framing |
| `package.json`, `tsconfig.json` | TS workspace for selected safe extensions; no lockfile vendored |
| `agent/extensions/account-profile-indicator.ts` | Persistent footer badge derived from the active profile directory |
| `agent/extensions/git-interceptor.ts` | Portable safety guard: prevents git editor hangs and blocks `--no-verify` |
| `agent/extensions/worker-configuration-guard.ts` | Portable Cloudflare/Wrangler guard for generated `worker-configuration.d.ts` |
| `agent/extensions/pi-cloak/`, `agent/cloak.json` | Generic redaction extension + config; no real secrets |
| `agent/extensions/pi-memory-compiler.ts`, `agent/memory-compiler.example.json` | Optional Obsidian memory capture through `claude-memory-compiler` |
| `agent/extensions/save-md/` | Utility command `/save-md <name>` |
| `agent/skills/{code-review,coding-standards,diagnosing-bugs,domain-modeling,handoff,herdr,tdd,tech-spec}` | Selected relevant engineering skills |
| `agent/skills/{improve-codebase-architecture,prototype,writing-great-skills,grilling}` | Selected personal/workflow skills: architecture scans, throwaway prototypes, skill authoring, and design stress-tests |
| `agent/skills/coding-agent-account-routing/` | Personal/work inheritance and external-worker account boundary |
| `agent/skills/subagent-routing/` | Direct-first delegation, model, placement, and fallback policy |
| `agent/pi-codex-subagents/` | Credential-free Codex subagent policy, config, and worker templates |
| `scripts/setup-pi-subagents.sh` | Opt-in installer for pinned `@ogulcancelik/pi-codex-subagents@0.3.2`; migrates legacy local stacks |
| `agent/themes/catppuccin-macchiato.json` | Public Catppuccin palette, updated to Pi's current `colors` schema |
| `agent/settings.example.json` | Credential-free defaults with a reviewed, version-pinned Codex compaction package; real file is gitignored |
| `agent/pi-codex-compaction.json` | Enables native Codex compaction at 90% context usage and shows a notification when it runs |
| `agent/models.work.example.json` | Credential-free work-profile detail-name template; model IDs and routing stay unchanged |
| `agent/mcp.example.json` | Local/disabled placeholder servers only |
| `templates/hermes/.../coding-agent-account-routing/SKILL.md` | Separates Hermes-native delegation from external Pi/Claude account selection |
| `scripts/setup-pi-profiles.sh` | Creates/checks the profile boundary without copying credentials or sessions |

## What was intentionally excluded

Copied nothing that is private, user-specific, or runtime state:

- **`agent/mcp.json` with private URLs** — the source referenced private
  provider endpoints and an auth token. Not copied. The example uses
  `REPLACE_ME` placeholders and stays disabled. `./dot pi doctor` rejects
  generic secret shapes in the scaffold and appends any project-specific
  private patterns from a local, gitignored blocklist
  (`DOTFILES_PI_BLOCKLIST`; see `config/dotfiles/local.env.example`).
- **`opencode-cloudflare` extension** and any private gateway / Cloudflare
  account overlay — not copied.
- **Private model IDs and provider endpoints** — the scaffold includes only the
  reviewed public model IDs required by the routing policy. Custom/private
  providers and credentials remain local.
- **Auth / session / cache state** — never copied; gitignored in the scaffold.
- **Live memory compiler config** — `agent/memory-compiler.json` is gitignored;
  the example contains only the local repo path and no credentials.
- **The full personal extension set and `.agents` skills** — only selected
  portable extensions/skills are adapted. The private/opinionated remainder
  stays out unless explicitly reviewed and added later.

## Personal and work profiles

Choose a local work-profile slug outside the public repository, then prepare
the second profile after the base scaffold exists:

```bash
# In ~/.config/dotfiles/local.env (example value only):
DOTFILES_PI_WORK_PROFILE_SLUG="clientx"

./dot pi profiles --dry-run
./dot pi profiles --apply
./dot pi profiles --check
```

The setup uses `~/.pi/agent` for personal and
`~/.pi/agent-$DOTFILES_PI_WORK_PROFILE_SLUG` for work. It shares credential-free
extensions, skills, themes, packages, and worker routing assets while keeping
auth, sessions, settings, MCP state, caches, and trust decisions separate. It
also installs the credential-free Hermes account-routing skill. Credentials
remain local and must be created through each profile's `/login` flow.

Use `pi-personal`, `pi-work`, or the generated `pi-<slug>` alias; do not use
model IDs as account evidence. In-process Pi Subagents reuse the parent
process's model registry and agent directory, so they automatically use the
parent profile. Fresh terminal or Herdr Pi workers must receive
`PI_CODING_AGENT_DIR` explicitly and their footer badge must be checked before
work is sent.

Hermes-native `delegate_task` children inherit Hermes provider credentials and
do not use Pi auth. Claude Code has another independent credential store;
selecting a Pi work profile does not select a corresponding Claude Code account.
Without an identity-verified work-account wrapper, fallback stays in the
selected Pi profile instead of launching bare `claude`.

## Codex native compaction

The personal-profile settings example pins
`@ogulcancelik/pi-codex-compaction@0.1.1`. The accompanying
`agent/pi-codex-compaction.json` enables provider-native compaction at 90%
context usage and displays a notification when it runs. It activates only for
`openai-codex` models; the independent Anthropic work profile is unaffected.
Native checkpoints are model-specific, so return to the Codex model that
created a checkpoint before continuing older compacted history.

Install it into an existing personal profile with:

```bash
PI_CODING_AGENT_DIR="$HOME/.pi/agent" \
  pi install npm:@ogulcancelik/pi-codex-compaction@0.1.1
cp "$DOTFILES_PI_SCAFFOLD_DIR/agent/pi-codex-compaction.json" \
  "$HOME/.pi/agent/pi-codex-compaction.json"
```

## Installing Pi subagents

The optional subagent stack is pinned to
`@ogulcancelik/pi-codex-subagents@0.3.2`. Apply the private scaffold first; the
installer refuses to continue unless the reviewed routing policy, `SYSTEM.md`,
config, and worker templates are present. It migrates the superseded local
`pi-subagents`/`pi-herdr` stack into `~/.pi/agent/migrations/`, removes stale
package identities, and installs exactly one pinned Codex subagent package:

```bash
./dot pi subagents --dry-run
./dot pi subagents --apply
./dot pi subagents --check

# Install/check the same package stack for the configured work profile:
PI_CODING_AGENT_DIR="$HOME/.pi/agent-$DOTFILES_PI_WORK_PROFILE_SLUG" \
  ./dot pi subagents --apply
PI_CODING_AGENT_DIR="$HOME/.pi/agent-$DOTFILES_PI_WORK_PROFILE_SLUG" \
  ./dot pi subagents --check
```

`PI_HOME`, `PI_CODING_AGENT_DIR`, and `DOTFILES_PI_SCAFFOLD_DIR` overrides are
honored consistently by the scaffold and package checks.
The routing skill is the policy source of truth. Pi executes directly by
default. It delegates only on explicit request or when parallelism, isolation,
specialist context, or independent consequential review materially helps.
Claude Code fallback is policy-authorized only for qualifying Claude-in-Pi
runtime failures, when tool access permits, and when the account-routing policy
allows that Claude Code identity. Work-profile fallback remains blocked without
an identity-verified wrapper. Assignments, cwd, and verification are preserved,
and the actual runtime/model/account boundary is disclosed. Poor output is
reviewed, not treated as runtime failure.

## Installing the pi CLI

Install the tested npm distribution:

```bash
npm install -g @earendil-works/pi-coding-agent@0.84.1
```

`./dot pi install` prints the command and prompts before running it. It requires
Node.js >=22.19 and npm outside Vite+'s managed runtime (system/NodeSource on
Linux or Homebrew on macOS). If the system global prefix is not writable, the
installer uses the user-owned `~/.local` prefix. After the npm executable passes a version check,
it removes only Vite+'s global Pi package
with `vp remove -g @earendil-works/pi-coding-agent`; Vite+ itself remains
available for project tooling.

The npm layout is intentional. A Pi CLI installed globally through Vite+ was
verified to fail runtime imports used by subagent and other extensions,
while the npm-installed CLI loaded the pinned source stack.
Pi is therefore listed in `packages/npm.global`.

## Safety checks

`./dot pi doctor` verifies: the scaffold and direct-first routing assets are present,
`~/.pi` state (if any) has no runtime auth files tracked by git, and the scaffold
is free of known private strings / live secret shapes. `./dot pi profiles
--check` verifies sensitive/runtime paths are not shared, and
`bash scripts/tests/pi-profiles.test.sh` exercises idempotence plus the
settings/auth/Cloak boundary in a temporary home. `./dot pi subagents --check`
verifies the pinned package, exact routing assets, and installed package entries. `git
diff --check` and `./dot doctor` also apply.
