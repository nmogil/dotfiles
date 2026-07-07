# chezmoi migration plan (not yet applied)

This repo does **not** use [chezmoi](https://chezmoi.io) yet. Dotfiles are
copied by the setup scripts (`setup.sh`, `setup-linux.sh`). This doc records the
intended future migration so it can happen in a later, isolated PR.

`./dot chezmoi <cmd>` is a thin passthrough to the real `chezmoi` binary. Until a
source directory exists it has nothing to manage; read-only commands like
`chezmoi diff` never mutate `$HOME`.

## Why migrate later, not now

- Setup scripts work today; migrating live `$HOME` configs is high-risk.
- chezmoi wants a `~/.local/share/chezmoi` source tree with `dot_`-prefixed
  files and templates — a mechanical but reviewable change on its own.
- Doing it separately keeps this PR reversible.

## Rough future shape

```
chezmoi/                 # or ~/.local/share/chezmoi
  dot_zshrc
  dot_gitconfig
  dot_tmux.conf
  dot_p10k.zsh
  private_dot_config/hunk/config.toml
  .chezmoiignore
```

## Safe exclusions (never put in chezmoi source)

Machine-specific, secret, or agent-generated state must stay out of version
control and out of chezmoi:

- `~/.hermes/` (env, provider keys, gateway state)
- `~/.claude/` and `~/.codex/` (agent state, sessions, credentials)
- `~/.ssh/` (keys, known_hosts)
- Obsidian vault internals (`~/obsidian/`, sync state)
- Any `.env` / provider API keys
- `repos.txt` (personal repo list — already gitignored)

## Migration steps (future PR)

1. `chezmoi init` against this repo.
2. `chezmoi add` each intended dotfile; rename to `dot_*` source form.
3. Add `.chezmoiignore` covering the exclusions above.
4. Verify with `chezmoi diff` (read-only) before any `chezmoi apply`.
5. Update setup scripts to `chezmoi apply` instead of copying, once verified.
