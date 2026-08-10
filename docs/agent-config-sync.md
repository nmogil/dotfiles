# Portable Herdr, Pi, and Hermes configuration

This repository owns the **credential-free configuration layer** for the three
agent tools. Machine identities, authentication, private endpoints, and runtime
state remain local by design.

## Host roles

Hermes is **VPS-only**. `DOTFILES_ENABLE_HERMES` defaults to `0`, so laptop and
workstation setup/doctor paths neither invoke nor require Hermes—even if a
`hermes` executable happens to be on `PATH`. Set it to `1` only in the
machine-local `local.env` of a VPS intended to run Hermes.

## One-time setup on a laptop or workstation (no Hermes)

Clone both repositories into the normal personal bucket, then set the private
Pi scaffold path and explicitly keep Hermes disabled:

```bash
git clone git@github.com:nmogil/dotfiles.git ~/github_repos/personal/dotfiles
git clone git@github.com:nmogil/dotfiles-private.git ~/github_repos/personal/dotfiles-private
mkdir -p ~/.config/dotfiles
printf '%s\n' \
  'DOTFILES_PI_SCAFFOLD_DIR="$HOME/github_repos/personal/dotfiles-private/pi-scaffold"' \
  'DOTFILES_ENABLE_HERMES=0' \
  >> ~/.config/dotfiles/local.env

cd ~/github_repos/personal/dotfiles
./dot pi install
./dot pi scaffold --apply
./dot pi profiles --apply
./dot pi subagents --apply
./dot herdr config --apply
for agent in pi claude codex; do
  command -v "$agent" >/dev/null 2>&1 && herdr integration install "$agent"
done
herdr plugin install persiyanov/herdr-reviewr --yes
./dot doctor
```

Do not install Hermes and do not run `./dot hermes ...`, `hermes ...`, or
`herdr integration install hermes` on these machines.

## Updating an existing laptop or workstation

After both companion PRs are merged:

```bash
git -C ~/github_repos/personal/dotfiles-private switch main
git -C ~/github_repos/personal/dotfiles-private pull --ff-only
git -C ~/github_repos/personal/dotfiles switch main
git -C ~/github_repos/personal/dotfiles pull --ff-only

cd ~/github_repos/personal/dotfiles
./dot pi install
./dot pi scaffold --apply
./dot pi profiles --apply
./dot pi subagents --apply
./dot herdr config --apply
for agent in pi claude codex; do
  command -v "$agent" >/dev/null 2>&1 && herdr integration install "$agent"
done
herdr plugin install persiyanov/herdr-reviewr --yes

./dot pi doctor
./dot pi profiles --check
./dot pi subagents --check
./dot herdr config --check
./dot doctor
```

## VPS with Hermes

Use the same Pi/Herdr steps, but set `DOTFILES_ENABLE_HERMES=1` in
`~/.config/dotfiles/local.env`. Install/update Hermes through its official
flow, then run:

```bash
cd ~/github_repos/personal/dotfiles
hermes config migrate
./dot hermes config --apply
herdr integration install hermes
hermes config check
./dot hermes config --check
```

`setup.sh` (macOS) and `setup-linux.sh` apply Herdr preferences everywhere and
Hermes preferences only when `DOTFILES_ENABLE_HERMES=1`. Linux setup installs
the Pi, Claude, and Codex Herdr integrations plus Reviewr; it installs the
Hermes integration only on an enabled VPS. Hermes itself continues to use its
official installer/update flow.

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
Hermes preferences. On an enabled VPS, `./dot hermes config --apply`
deep-merges it into `~/.hermes/config.yaml`, preserving unknown/local sections.

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

On every machine:

```bash
./dot herdr config --check
./dot pi doctor
./dot pi profiles --check
./dot pi subagents --check
bash scripts/tests/agent-configs.test.sh
```

On an enabled Hermes VPS, also run:

```bash
./dot hermes config --check
```

The `--check` modes are read-only. `./dot doctor` reports portable config drift
as a warning and treats missing tracked templates/scripts as a hard failure.
