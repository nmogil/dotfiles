# AGENTS.md — working in this dotfiles repo

Context for agents (and humans) editing this repo. This is Noah's personal
machine + VPS setup. Prefer small, reversible changes.

## Control surface

`./dot <command>` is the front door — a thin wrapper over the existing scripts.
Run `./dot help` for the list. It does not duplicate script logic; it locates
and dispatches to them.

## Where to edit common things

| Change | Edit |
|--------|------|
| macOS packages | `Brewfile` |
| Linux/VPS packages | `setup-linux.sh` (authoritative) + mirror in `packages/apt.*` |
| Global npm CLIs | `setup-linux.sh` / `setup-obsidian-sync.sh` + `packages/npm.global` |
| Shell config | `.zshrc`, `.p10k.zsh` |
| Git config | `.gitconfig` |
| tmux | `.tmux.conf` |
| Hunk / Ghostty | `config/hunk/config.toml`, `config/ghostty/config` |
| macOS setup steps | `setup.sh` |
| Linux setup steps | `setup-linux.sh` |
| Repo cloning | `clone-repos.sh` (list lives in gitignored `repos.txt`) |
| Local/private overrides | `~/.config/dotfiles/local.env` (template: `config/dotfiles/local.env.example`) |
| Git identity | `~/.config/dotfiles/local.env` (`DOTFILES_GIT_NAME`/`_EMAIL`) or `~/.config/git/local.gitconfig` — not tracked |
| Workstream buckets | `DOTFILES_REPO_BUCKETS` in `local.env` (default `personal ventures external`) |
| VPS hardening | `harden-vps.sh` |
| Obsidian sync | `setup-obsidian-sync.sh` |
| VPS memory/systemd guardrails | `server/` |
| Health checks | `scripts/doctor.sh` |
| Pi agent scaffold | `templates/pi/` + `scripts/setup-pi-agent.sh` (opt-in; see `docs/pi-agent-setup.md`) |
| Pi account profiles | `.zshrc` + local profile slug + `templates/{pi,hermes}/` + `scripts/setup-pi-profiles.sh` |
| Pi subagents/model routing | `templates/pi/agent/{agents,skills/subagent-routing}` + `scripts/setup-pi-subagents.sh` |
| Future chezmoi migration | `docs/chezmoi-plan.md` (not applied yet) |

Package manifests under `packages/` are documentation + input for
`./dot packages check`; the setup scripts remain the source of truth for install.

## Safety rules

- **Never commit secrets.** No API keys, tokens, `.env` files, SSH keys.
  `repos.txt` stays gitignored. Run `./dot doctor` — it flags tracked secrets.
- **Do not edit live `$HOME` configs directly.** Edit the repo copy; let the
  setup scripts apply it. (chezmoi is not wired up yet — see the plan doc.)
- **Keep workstream separation.** Do not cross-pollinate configured workstream
  buckets (default `personal` / `ventures` / `external`, plus any codenamed
  employer/client buckets defined locally) — repos, tokens, tracker updates.
  Bucket names and any private codenames live in `local.env`, never tracked.
- **Do not weaken VPS hardening.** `harden-vps.sh` and `server/` drop-ins exist
  on purpose; don't loosen firewall, SSH, or OOM/memory guardrails to make
  something convenient.
- **Pi scaffold stays inert and credential-free.** `templates/pi/` may contain
  reviewed public model IDs used by the routing policy, but no real provider
  endpoints, tokens, or private MCP servers. The private-endpoint/token
  blocklist enforced by `./dot pi doctor` lives locally and gitignored
  (`DOTFILES_PI_BLOCKLIST`; see `config/dotfiles/local.env.example`) so the
  public repo does not enumerate private strings. Real credential-bearing
  config is created locally and stays gitignored. Nothing installs into `~/.pi`
  or the Pi package list without an explicit `./dot pi ... --apply` command.
- **Do not migrate agent/secret state into this repo:** `~/.hermes`, `~/.claude`,
  `~/.codex`, `~/.ssh`, Obsidian vault internals, env/provider keys, generated
  agent state. See `docs/chezmoi-plan.md` "Safe exclusions".

## Verify changes

```bash
bash -n dot scripts/doctor.sh scripts/setup-pi-agent.sh \
  scripts/setup-pi-profiles.sh scripts/setup-pi-subagents.sh setup.sh setup-linux.sh clone-repos.sh \
  harden-vps.sh setup-obsidian-sync.sh   # syntax-check shell scripts
bash scripts/tests/local-env.test.sh      # local override + portable defaults
bash scripts/tests/pi-profiles.test.sh     # profile isolation + idempotence
./dot doctor                              # read-only health check
./dot pi doctor                           # Pi scaffold checks (read-only)
./dot packages check                      # installed vs declared packages
```

Prefer read-only commands (`./dot doctor`, `./dot chezmoi diff`, `./dot packages
check`) when confirming state — none of them mutate the system.
