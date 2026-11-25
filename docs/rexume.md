# rexume

[rexume](https://github.com/Entwining/rexume) (MIT) is a daemon that sits
beside the Rex server:

- **Restores.** After the Rex server restarts (a crash, a reboot, an upgrade),
  Rex brings its sessions, tabs and panes back, each with a fresh shell.
  rexume then reopens the conversation that was running in each pane (Claude
  Code, Codex, Pi, omp, OpenCode). It types a short `rexume gate` line into the
  restored shell, and only when the shell shows an empty prompt. A turn that
  was cut off continues once.
- **Worker results.** An orchestrating agent registers the workers it starts
  in other panes (`rexume task add`), and rexume sends it a notice when each
  worker finishes or blocks. Its skill (`rexume skill show`) teaches agents
  how to use this.

Its state (recorded panes, conversations, task results) lives in
`~/.local/state/rexume/`. Upstream's docs: `docs/setup.md`, `docs/usage.md`
and `docs/cli.md` in the rexume repository.

## Install (opt-in)

```sh
./dot rexume              # dry-run: what --apply would do (writes nothing, no network)
./dot rexume --apply      # install the binary if missing, then `rexume install`
./dot rexume --check      # 0 ok, 3 not installed at all, 1 anything else (with the reason)
```

`--apply` does these steps in order. It stops at the first one that fails.

1. **Work-profile guard** (see below). It refuses if any `~/.pi/agent-*`
   profile has `extensions/rexume.ts`, or shares `~/.pi/agent/extensions`.
2. **Rex server probe** (read-only; see below). It refuses on a server older
   than 0.1.0-preview.23.
3. **The binary.**
   - **macOS (Apple Silicon, macOS 15+; upstream has no Intel build):**
     Homebrew owns it (`Brewfile`: `entwining/tap/rexume`). `--apply` runs
     `brew install` only when it is missing. It never upgrades, reinstalls or
     removes it, and it rejects `--force`. Checks ask Homebrew only for
     `brew --cellar` and flag a `rexume` on PATH that did not come from
     Homebrew.
   - **Linux (x86_64):** the release pinned in `config/rexume/release.pins`.
     `--apply` downloads the pinned archive and checks its SHA-256. Upstream
     requires a GitHub attestation check, so it then runs
     `gh attestation verify <archive> --repo Entwining/rexume
     --signer-workflow Entwining/rexume/.github/workflows/publish.yml`. If `gh`
     is missing or verification fails, nothing is installed. Last, it checks
     the SHA-256 of `bin/rexume` inside the archive. Only then is
     `~/.local/bin/rexume` written. It is published with `link` (never
     overwrites) or, with `--apply --force`, replaced by an exact rename after
     the old binary is backed up and the backup verified (to
     `~/.local/state/dotfiles/rexume-backups/`). Symlinks and directories are
     refused. This is the same code as rexboard (`scripts/lib/pinned-release.sh`).
4. **`rexume install`**, with `PI_CODING_AGENT_DIR` removed from its
   environment (`env -u PI_CODING_AGENT_DIR`). On Linux, `~/.local/bin` is put
   on its `PATH` if it isn't there already. rexume records that `PATH` for the
   daemon, and its hooks run `rexume` by name. `rexume install` writes the
   Claude Code hooks and plugin, the Codex hook (trust it in Codex's `/hooks`),
   the Pi extension `~/.pi/agent/extensions/rexume.ts`, the omp and OpenCode
   plugins where those exist, the skill stubs, and the daemon job: the
   LaunchAgent `io.github.entwining.rexume` on macOS, or the systemd user
   service `rexume.service` on Linux. `--apply` prints rexume's JSON summary
   as one line, plus any notes.
5. It checks the work profiles again, then runs `--check`.

Rerunning `--apply` is safe. `rexume install` is idempotent, and rerunning it
picks up runtimes installed since the last run.

`setup-linux.sh` does not run this step. Run it by hand once the Rex server is
new enough. On Linux, systemd runs user services only while you are logged in.
If the Rex server outlives your login, run `loginctl enable-linger` once.

### `--check`

`--check` exits 0 when all of these hold:

- the binary is present: on macOS from Homebrew (any version), on Linux
  matching the pin;
- the daemon job is active: `systemctl --user is-active rexume`, or
  `launchctl print gui/$(id -u)/io.github.entwining.rexume` showing
  `state = running`;
- `~/.pi/agent/extensions/rexume.ts` exists;
- no `~/.pi/agent-*/extensions/rexume.ts` exists;
- `rexume status` succeeds and lists no missing Claude Code hooks.

It exits 3 when there is no trace of rexume (no binary, extension, job file or
running daemon), and 1 otherwise, with each reason. Checks never run the
binary except the read-only `rexume status`, and only after the binary is
verified (from Homebrew, or matching the pin). `./dot doctor` runs the check
where Rex or rexume is present.

## Rex version requirement

rexume 0.1.28 needs the Rex server **0.1.0-preview.23 or later**, and its CLI
with it. Its hooks and skill pass a pane's block ID where Rex expects a session
ID. An older server refuses that, and the hooks then record nothing to reopen.
Before `rexume install`, `--apply` checks this without changing anything. It
runs `rex --autostart=false ls --json`, picks any block ID from
`rex block ls --json -s <session>`, and requires
`rex block ls --json -s <that block ID>` to succeed. If it fails, upgrade the
server first: `rex-safe-upgrade` on Linux, or update the Rex app on the Mac
(`rex server status` shows the running server's version). If the server has no
pane at all, the requirement can't be verified, so `--apply` refuses. The probe
never starts, stops or restarts the server.

## Work profile: never gets the extension

The work Pi profile (`~/.pi/agent-<slug>`, launched by the `pi-work` shell
function with `PI_CODING_AGENT_DIR` set) must never load rexume's Pi
extension. When rexume reopens a conversation, it starts `pi` without
`PI_CODING_AGENT_DIR`, so a work conversation would come back under the
personal profile, with personal models and credentials. With no extension in
the work profile, its sessions are never recorded, so rexume never reopens
them. After a restart, reopen work conversations yourself (or with
`rex-safe-upgrade`).

The installer enforces this:

- `rexume install` always runs with `PI_CODING_AGENT_DIR` removed. Run from a
  `pi-work` shell, it would otherwise write the extension into the work
  profile, and the job would keep the variable.
- `--apply` refuses before installing anything if a work profile has
  `extensions/rexume.ts`, or if its `extensions` directory is the personal one
  (a symlink to `~/.pi/agent/extensions`): `rexume install` writes there, and
  the work profile would load it.
- `--check` fails while any `~/.pi/agent-*/extensions/rexume.ts` exists.

**Current layout:** `setup-pi-profiles.sh` (`./dot pi profiles`) links the
work profile's `extensions` directory to the personal one. Until the work
profile gets an extensions directory of its own, `--apply` refuses with
"shares ~/.pi/agent/extensions". Don't work around this by hand.

If you run `rexume install` or `rexume uninstall` by hand, use
`env -u PI_CODING_AGENT_DIR rexume install` (or `uninstall`). If a work
profile ever gets `rexume.ts`, delete that file. rexume marks it
`// Written by \`rexume install\``.

## Coexistence with rex-safe-upgrade

`rex-safe-upgrade` (`docs/rex-safe-upgrade.md`) owns planned Rex server
upgrades on Linux. rexume handles unplanned restarts. Both reopen
conversations after a restart, so only one may act on a planned upgrade. The
change that makes `rex-safe-upgrade run` pause rexume during the upgrade and
resume it afterwards is in another PR (branch
`feat/rex-safe-upgrade-preview23`), not on this branch. Until it merges,
don't run `rex-safe-upgrade run` on a Linux host where rexume is installed.
The Mac has no `rex-safe-upgrade`.

## What the installer never does

- Stop, start or restart the Rex server, or type into panes. rexume itself
  types its `rexume gate` line into restored panes, as described above.
- Upgrade or remove the Homebrew rexume, or replace a differing Linux binary
  without `--force`.
- Touch `~/.local/state/rexume/`.
- Run any rexume command other than `rexume install` (in `--apply`) and
  `rexume status` (in checks).

## Uninstall

```sh
env -u PI_CODING_AGENT_DIR rexume uninstall
```

This stops and removes the daemon job, and removes rexume's hooks, Claude Code
plugin, Pi/omp extensions, OpenCode plugin and skill stubs. It **keeps
`~/.local/state/rexume/`** (recorded panes, conversations, task results).
Delete that directory yourself if you want them gone. Then remove the program:
`rm ~/.local/bin/rexume` on Linux, or on the Mac `brew uninstall rexume` and
also remove its `Brewfile` line, or `brew bundle` reinstalls it.

## Updating the pin

macOS follows Homebrew (`brew upgrade`). Linux follows the pin. To move it:

1. Read the upstream release notes (`docs/releases/<version>.md` in the
   rexume repository) between the pinned and the new version, especially the
   Rex version requirement and state database migrations. A new version may
   migrate `~/.local/state/rexume/state.db` so older versions refuse it, so
   downgrading is not supported.
2. Download and verify the new archive:
   ```sh
   gh release download v<new> --repo Entwining/rexume \
     --pattern 'rexume-<new>-x86_64-unknown-linux-musl.tar.gz*'
   shasum -a 256 -c rexume-<new>-x86_64-unknown-linux-musl.tar.gz.sha256
   gh attestation verify rexume-<new>-x86_64-unknown-linux-musl.tar.gz \
     --repo Entwining/rexume --signer-workflow Entwining/rexume/.github/workflows/publish.yml
   tar -xzf rexume-<new>-x86_64-unknown-linux-musl.tar.gz
   shasum -a 256 rexume-<new>-x86_64-unknown-linux-musl/bin/rexume
   ```
3. Update every value in `config/rexume/release.pins` together (version, URL,
   archive, both checksums, member path). Then run
   `bash scripts/tests/rexume.test.sh`.
4. On the VPS, run `./dot rexume --apply --force`. It backs up the old binary.
   The running daemon notices that its executable was replaced and its job
   starts the new one.

## Verification

```sh
bash scripts/tests/rexume.test.sh     # fixture release over file://; stub uname/brew/gh/rex/systemctl/launchctl
bash scripts/tests/rexboard.test.sh   # the shared pinned-release library
./dot rexume --check
```
