# rexboard

[rexboard](https://github.com/vanducng/rexboard) (MIT) is an attention board
for the coding agents running in Rex panes across every Rex host: which one is
working, blocked, or done, and a jump to its pane. Run `rexboard` in any
terminal. Its first run starts `rexboard serve` in the background, which
watches this host and every host in `rex hosts`; its state lives in
`~/.local/state/rexboard/`. It needs no Pi extension: agents running directly
in a Rex pane report on their own.

## Install

```sh
./dot rexboard              # dry-run: what --apply would do
./dot rexboard --apply      # install if missing
./dot rexboard --check      # 0 ok, 3 not installed, 1 differs or a problem
```

- **macOS (Apple Silicon; upstream ships no Intel build):** Homebrew owns it
  (`Brewfile`: `vanducng/tap/rexboard`), so `brew bundle` and `brew upgrade`
  keep it current. `--apply` runs `brew install` only when it is missing; it
  never upgrades, reinstalls, or removes it (`--force` is rejected). `--check`
  accepts any Homebrew version and flags a `rexboard` on PATH that did not
  come from Homebrew or shadows Homebrew's. It asks Homebrew only for
  `brew --cellar` (a path lookup) and reads the Cellar itself.
- **Linux (x86_64):** the release pinned in `config/rexboard/release.pins`.
  `--apply` downloads that archive and checks its SHA-256 and the binary's
  against the pins before touching `~/.local/bin/rexboard`. A missing binary
  is published with `link`, which never overwrites anything that appeared in
  the meantime; a forced replacement is a rename of exactly that path. A
  binary that already matches is left alone (no download; a missing execute
  bit is restored). A different binary is left alone too; `--apply --force`
  backs it up to `~/.local/state/dotfiles/rexboard-backups/` first and
  verifies the backup. Symlinks and directories are refused. The status covers
  `~/.local/bin/rexboard` and flags another `rexboard` ahead of it on PATH.
  Upstream publishes no other Linux build. `setup-linux.sh` offers this step.

The release has no GitHub attestation, so the pins are the trust anchor. The
archive checksum matches the release's `SHA256SUMS`; the binary checksum is of
the `rexboard` file inside that archive, and matches the copy on the VPS.
`release.pins` is read as data, never sourced. Checks never run the binary.

## What the installer never does

- Start, stop, or restart `rexboard serve`. After an upgrade, a running serve
  keeps its old binary until it restarts.
- Run `rexboard hooks install`. Hooks are only for agents inside tmux; run it
  by hand (`--dry-run` first) if you need it.
- Touch `~/.local/state/rexboard/` or any config.

## `./dot update` and doctor

`./dot update` runs `./dot rexboard --check` and nothing else: a match is ✓,
not installed is a skip, and a differing binary is a warning. It never
installs or replaces rexboard, so a hand-installed or Homebrew-upgraded copy
is never undone. `./dot doctor` reports the same check where Rex or rexboard
is present.

## Updating the Linux pin

rexboard releases often. To move the pin:

1. Read the upstream changes between the pinned and the new tag.
2. Download the new `x86_64-unknown-linux-gnu` archive and `SHA256SUMS`;
   confirm the archive checksum matches, extract it, and hash the
   `rexboard` binary inside.
3. Update every value in `config/rexboard/release.pins` together, then run
   `./dot rexboard --apply --force` on the VPS (it backs up the old binary).

## Verification

```sh
bash scripts/tests/rexboard.test.sh   # fixture release over file://; stub uname/brew
bash scripts/tests/update.test.sh     # update runs only the read-only check
./dot rexboard --check
```
