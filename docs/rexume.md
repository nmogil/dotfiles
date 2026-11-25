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
`~/.local/state/rexume/`. The daemon creates that directory and its database
when it first starts, and a newer rexume migrates the database when its daemon
starts. An older rexume then refuses to open it. Upstream's docs: `docs/setup.md`, `docs/usage.md`
and `docs/cli.md` in the rexume repository.

## Install (opt-in)

```sh
./dot rexume              # dry-run: what --apply would do (writes nothing, no network)
./dot rexume --apply      # install the binary if missing, then `rexume install`
./dot rexume --check      # 0 ok, 3 not installed at all, 1 anything else (with the reason)
```

`--apply` does these steps in order. It stops at the first one that fails.

1. **Profiles lock.** It takes `~/.pi/.dotfiles-profiles.lock`, which
   `./dot pi profiles --apply` also takes, and holds it to the end (see
   below).
   **No work Pi profile.** It refuses if any work Pi profile exists (see
   below). It also refuses if the personal `rexume.ts` is a symlink, or the
   personal profile or extensions path is a symlink that doesn't resolve,
   since `rexume install` would write through it.
2. **Conflicting `rexume` on PATH** (Linux). It refuses before changing
   anything if a `rexume` other than `~/.local/bin/rexume` comes first on the
   caller's PATH, or if `~/.local/bin` isn't on PATH and a `rexume` is. (macOS:
   it refuses a `rexume` on PATH that isn't Homebrew's.)
3. **Preflight.** On Linux, `XDG_RUNTIME_DIR` and `systemctl` are required; on
   macOS, `launchctl`. Then the **Rex server probe** (read-only; see below).
   It refuses on a server older than 0.1.0-preview.23.
4. **The binary.**
   - **macOS (Apple Silicon, macOS 15+; upstream has no Intel build):**
     `brew install entwining/tap/rexume`, only when rexume is missing. It is
     deliberately not in the `Brewfile`, so `brew bundle` never installs it.
     `--apply` never upgrades, reinstalls or removes it, and it rejects
     `--force`. macOS before 15 is refused with a clear message. Checks ask
     Homebrew only for `brew --cellar` and flag a `rexume` on PATH that did not
     come from Homebrew.
   - **Linux (x86_64):** the release pinned in `config/rexume/release.pins`.
     `--apply` downloads the pinned archive and checks its SHA-256. Upstream
     requires a GitHub attestation check, so it then runs
     `gh attestation verify <archive> --repo Entwining/rexume
     --signer-workflow Entwining/rexume/.github/workflows/publish.yml`. If `gh`
     is missing, or verification fails, nothing is installed. Last, it checks
     the SHA-256 of `bin/rexume` inside the archive. Only then is
     `~/.local/bin/rexume` written. It is published with `link` (never
     overwrites) or, with `--apply --force`, replaced by an exact rename after
     the old binary is backed up and the backup verified (to
     `~/.local/state/dotfiles/rexume-backups/`). Symlinks and directories are
     refused. This is the same code as rexboard (`scripts/lib/pinned-release.sh`).
5. **`rexume install`**, after the work-profile guard runs again, with
   `PI_CODING_AGENT_DIR` removed from its environment
   (`env -u PI_CODING_AGENT_DIR`). On Linux, `~/.local/bin` is put on its
   `PATH` if it isn't there already. rexume records that `PATH` for the
   daemon. `rexume install` writes the Claude Code hooks and plugin, the Codex
   hook (trust it in Codex's `/hooks`), the Pi extension
   `~/.pi/agent/extensions/rexume.ts`, the omp and OpenCode plugins where those
   exist, the skill stubs, and the daemon job: the LaunchAgent
   `io.github.entwining.rexume` on macOS, or the systemd user service
   `rexume.service` on Linux. `--apply` prints rexume's JSON summary as one
   line, plus any notes.
6. It checks the work profiles again. It then waits up to 20 seconds for the
   daemon to run and `rexume status` to succeed: status fails until the
   daemon has created its database. Then it runs `--check`.

**Agent runtimes need the right `rexume` on their own PATH.** The hooks and
extensions run `rexume` by name, from each agent's environment, not the
daemon's. On Linux that means `~/.local/bin` must be on the PATH your shells
and agents start with (`.zshrc` adds it), ahead of any other `rexume`. On
macOS, Homebrew's `bin` must be on it.

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
- `~/.pi/agent/extensions/rexume.ts` exists (and isn't a symlink);
- no work Pi profile exists;
- `rexume status` succeeds and returns `claude_hooks_missing` as an empty list.
  `null` (rexume couldn't read the Claude Code settings) or a missing field
  fail the check, and so do missing hooks.

It exits 3 when there is no trace of rexume (no binary, extension, job file or
running daemon), and 1 otherwise, with each reason. On Linux, a `rexume` on
PATH that isn't the pinned `~/.local/bin/rexume` is a problem (1), not
absence. A standalone `--check` never waits: right after an install, run it
again if the daemon hasn't created its database yet. Every `systemctl`,
`launchctl` and `rexume status` call is bounded (10 seconds each,
`DOTFILES_REXUME_CALL_TIMEOUT`), and `--apply`'s readiness wait is a real
20-second deadline (`DOTFILES_REXUME_READY_TIMEOUT`). `--dry-run` writes
nothing, not even a temp file: the installer and its libraries use no heredocs
or here-strings, which bash 3.2 writes to temp files. A test enforces this. Checks never run the
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
never stops or restarts the server. `--autostart=false` stops the `rex` CLI from
starting a missing server itself. A socket-activated service (for example a
systemd socket unit for Rex) could still start one when the probe connects.

## Work profile: rexume and a work Pi profile never coexist

The work Pi profile (`~/.pi/agent-<slug>`, launched by the `pi-work` shell
function with `PI_CODING_AGENT_DIR` set) must never load rexume's Pi
extension. When rexume reopens a conversation, it starts `pi` without
`PI_CODING_AGENT_DIR`, so a work conversation would come back under the
personal profile, with personal models and credentials.

Pi profiles share the personal `extensions` directory
(`./dot pi profiles` links it). Under that model, no check on individual
files can keep `rexume.ts` out of a work profile. A link under another name
gets through, and so does a profile created while rexume installs. So the
rule is at the profile level, and fails closed:

- **`./dot rexume --apply` refuses on any machine with a work Pi profile.** A
  work profile is any `~/.pi/agent-*` entry: a directory, a symlink (dangling
  too) or a file. The only exception is `~/.pi/agent-memory` when it is a
  plain directory with neither `settings.json` nor `extensions` (the VPS's
  memory data directory). The message lists the profiles. rexume can't be
  installed on such a machine until Pi profiles stop sharing `extensions`.
  That is Noah's decision, separate from this installer. The check runs again
  right before `rexume install`.
- **`./dot pi profiles --apply` refuses to create or update a work profile
  while rexume is installed.** Installed means any of: `rexume.ts` in the
  personal extensions, `~/.local/bin/rexume`, the systemd unit or
  LaunchAgent, or a `rexume` on PATH. `./dot pi profiles --check` fails when
  rexume and a work profile coexist.
- **One lock.** Both `--apply`s take `~/.pi/.dotfiles-profiles.lock` (an
  atomic `mkdir`, holding the owner's pid) for their whole check-and-write, so
  neither can slip in between the other's check and its writes. A second run
  waits up to 10 seconds (`DOTFILES_PROFILES_LOCK_TIMEOUT`), then refuses and
  names the holder. A lock whose pid is gone is taken over. A lock without a
  pid is never taken over: remove it by hand once you're sure nothing is
  running.
- `rexume install` always runs with `PI_CODING_AGENT_DIR` removed.
- `./dot rexume --check` fails while rexume is installed and any work profile
  exists.

**On this Mac today** (`~/.pi/agent-work`, sharing `extensions`),
`./dot rexume --apply` refuses. Don't work around it by hand.

The skill stub `~/.agents/skills/rexume/SKILL.md` would be read by every Pi
profile (and by Codex and OpenCode). That is acceptable: it only tells an agent
to run `rexume skill show`.

If you run `rexume install` or `rexume uninstall` by hand, use
`env -u PI_CODING_AGENT_DIR rexume install` (or `uninstall`).

## Claude Code plugin: forgeable messages

Upstream warns that rexume's Claude Code plugin submits every message on a
conversation's messaging socket that starts with a rexume token
(`[rexume …]`) as if you had typed it. It does not check that rexume wrote
the message. Another session's model can therefore forge such a message and
skip the approval your inbound-message rules (`crossSessionInbound`) would
otherwise require. A session that can run commands could reach the
conversation through `rexume task send` anyway. Install rexume only where you
accept that. See "Claude Code messages" in upstream's `docs/usage.md`.

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
`rm ~/.local/bin/rexume` on Linux, or `brew uninstall rexume` on the Mac (it is
not in the `Brewfile`, so `brew bundle` won't bring it back).

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
bash scripts/tests/rexume.test.sh     # fixture release over file://; stubs on an allowlisted temp-only PATH
bash scripts/tests/pi-profiles.test.sh  # no work profile while rexume is installed; the shared lock
bash scripts/tests/rexboard.test.sh   # the shared pinned-release library
./dot rexume --check
```
