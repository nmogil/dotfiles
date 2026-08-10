# Portable Herdr, Pi, and Hermes configuration

This repository now owns the **credential-free configuration layer** for the
three agent tools. Machine identities, authentication, private endpoints, and
runtime state remain local by design.

## One-time setup on another machine

Clone both repositories into the normal personal bucket, then set the private
Pi scaffold path:

```bash
git clone git@github.com:nmogil/dotfiles.git ~/github_repos/personal/dotfiles
git clone git@github.com:nmogil/dotfiles-private.git ~/github_repos/personal/dotfiles-private
mkdir -p ~/.config/dotfiles
printf '%s\n' \
  'DOTFILES_PI_SCAFFOLD_DIR="$HOME/github_repos/personal/dotfiles-private/pi-scaffold"' \
  >> ~/.config/dotfiles/local.env

cd ~/github_repos/personal/dotfiles
./dot pi install
./dot pi scaffold --apply
./dot pi profiles --apply
./dot pi subagents --apply
./dot herdr config --apply
./dot hermes config --apply
./dot doctor
```

`setup.sh` (macOS) and `setup-linux.sh` also apply the portable Herdr/Hermes
preferences. Linux setup installs the Pi, Claude, Codex, and Hermes Herdr
integrations when each CLI is present, plus the Reviewr plugin. Hermes itself
continues to use its official installer/update flow; after installing it, run
`hermes config migrate` before `./dot hermes config --apply`.

## What is synchronized

### Herdr

`templates/herdr/` owns:

- Vesper theme and pane-history preference
- agent labels and panel sorting
- sound disabled
- Reviewr toggle bindings (`cmd+r` and `prefix+shift+v`)
- Reviewr split/right placement and matching theme

`./dot herdr config --apply` backs up differing files and installs exact copies.
The Reviewr plugin binary and agent integrations are installed by the platform
setup scripts, not stored in Git.

### Pi

The public repository owns the installer, doctor, routing, profile separation,
and tests. The private companion repository owns `pi-scaffold/` because it
contains the full curated setup and is not suitable for public redistribution.

Current pins:

- `@earendil-works/pi-coding-agent@0.84.1`
- `@ogulcancelik/pi-codex-subagents@0.3.2`
- the exact personal-profile package list in
  `dotfiles-private/pi-scaffold/agent/settings.example.json`

The scaffold never includes `auth.json`, live `settings.json`, private MCP
servers, sessions, package caches, or trust state.

### Hermes

`templates/hermes/config.portable.yaml` is an allowlisted subset of the active
Hermes preferences. `./dot hermes config --apply` deep-merges it into
`~/.hermes/config.yaml`, preserving unknown/local sections.

It synchronizes model/UI/tool/delegation/security/memory/session preferences and
the credential-free plugin enablement list. It deliberately rejects endpoint-
or secret-shaped keys and values in the portable template.

## Deliberately local-only

Never add any of the following to either portable template:

- `.env`, provider keys, OAuth tokens, cookies, or gateway identities
- Slack/Telegram/Discord allowlists, user IDs, chat IDs, or webhook URLs
- private MCP server URLs, commands, environment variables, or auth blocks
- Hermes memories, session transcripts, cron state, caches, or plugin data
- Pi `auth.json`, live `settings.json`, `mcp.json`, sessions, package caches, or
  trust state
- Herdr sessions, pane state, sockets, logs, plugin lock/runtime data

## Drift checks

```bash
./dot herdr config --check
./dot hermes config --check
./dot pi doctor
./dot pi profiles --check
./dot pi subagents --check
bash scripts/tests/agent-configs.test.sh
```

The `--check` modes are read-only. `./dot doctor` reports portable config drift
as a warning and treats missing tracked templates/scripts as a hard failure.
