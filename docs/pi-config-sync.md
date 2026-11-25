# Personal Pi configuration across machines

The Mac's live **personal** Pi configuration is the authority. Capture reviewed
changes into the private dotfiles companion, then apply that baseline on other
machines. Do not copy the whole `~/.pi` directory or sync profiles bidirectionally.

The sync tooling requires Python 3.9+ and an installed Pi CLI matching the
baseline version. A missing/mismatched CLI fails the check deliberately; it does
not silently downgrade or install Pi.

## Ownership

- **Public dotfiles:** `scripts/sync-pi-config.{sh,py}`, tests, CLI version pin,
  and this workflow. The tools do not embed personal configuration.
- **Private companion:** `pi-config/manifest.json` and `pi-config/files/` hold
  the credential-free portable snapshot. It is separate from the historical
  `pi-scaffold/`, which remains a bootstrap template, not the current baseline.
- **Each machine:** credentials, auth/OAuth state, MCP configuration, provider
  endpoints/model stores, trust, sessions, caches, memory destinations, account
  profiles, project configuration, and machine-specific integrations.

Set `DOTFILES_PI_CONFIG_DIR` in the gitignored
`~/.config/dotfiles/local.env` to the private baseline directory. When omitted,
`./dot pi config` uses `pi-config` beside `DOTFILES_PI_SCAFFOLD_DIR`.

## Capture on the Mac

```sh
./dot pi config capture           # preview, no writes
./dot pi config capture --apply   # refresh the private snapshot from this Mac
./dot pi config apply --apply     # record ownership; normally no config changes
./dot pi config check             # fail on portable configuration/version drift
```

Review the diff in **both** dotfiles repositories before committing. No command
commits, pushes, transfers credentials, or updates Pi itself. Snapshot checksums
protect against accidental edits/corruption; they are not a trust signature.
The tool rejects symlinks, non-portable paths, common credential shapes, URLs in
portable settings, and unpinned/non-npm package declarations except the explicitly
approved floating `npm:@ogulcancelik/pi-codex-compaction` source. This is a guard,
not a substitute for reviewing extension and skill contents for secrets. The
local `DOTFILES_PI_BLOCKLIST` is also honored (Python-compatible regexes).

## Apply on another machine

Transfer the reviewed public tooling and the private `pi-config/` directory
through your normal repository workflow, preserving unrelated uncommitted work.
Then run, from outside a project with its own Pi settings:

```sh
./dot pi config apply             # preview only
./dot pi config apply --apply     # back up changed files, then apply
./dot pi config packages          # preview missing/mismatched installed packages
./dot pi config packages --apply  # install exact pins and refresh floating compaction
./dot pi config check
rex skill setup                  # optional; installed by Rex, not this snapshot
```

The packages command runs `pi install` for each missing/mismatched exact pin
and refreshes the floating Codex compaction package on every explicit invocation,
with the personal profile explicitly selected and project configuration disabled.
It does not update Pi itself. On Pi 1.4.0, `pi update --extensions` was observed
to leave mismatched pinned packages untouched, so do not use it as proof of
reconciliation. `check` verifies actual installed package versions as well as
settings. For floating compaction, `check` verifies installation, not registry
freshness; `packages --apply` or `pi update --extension npm:@ogulcancelik/pi-codex-compaction`
refreshes it. Unpinning alone does not schedule updates. Run
`node scripts/tests/pi-compaction-tools.test.mjs` after updates.
Local extensions in the baseline never carry `node_modules`. When a managed
extension's `package.json` declares runtime `dependencies` (for example the
`mpl` chart extension), `check` fails until each has an installed
`node_modules/<name>/package.json` in the extension directory or a parent such
as an `~/.pi` npm workspace (a presence check, not a module load). `packages
--apply` then runs `npm install` in that extension directory, but only after
`apply --apply` has made its `package.json` match the baseline. With an `~/.pi`
workspace, npm installs at the workspace root and updates that root's lockfile.
Dev dependencies are not checked.
Removed declarations stop loading, but old cached packages are not
deleted. Restart Pi after package changes; running sessions may still contain
previously loaded extensions or skills.

`./dot update` runs `apply --apply`, `packages --apply`, and `check` for you,
but only after both dotfiles repos fast-forwarded cleanly and the baseline is
tracked and clean in the verified private commit. It skips apply (unless
`--yes`) when `check` already showed file drift before pulling — that may be
uncaptured local work — or could not run, or when there was no baseline before
pulling but `~/.pi/agent` exists. Package-only drift does not block. Apply
backs up what it replaces; a failed `packages` step leaves Pi partially applied
until rerun. See the README's "Updating".

The installed Pi CLI must match `manifest.json`'s `piVersion`. Both machines
currently use **1.6.0**; the public CLI installer and package manifest pin that
version too. Change those pins deliberately when upgrading the source machine.

## What is managed

- Portable settings: theme, model defaults/allowlist, package sources (exact
  versions except deliberately floating Codex compaction),
  thinking, UI, and explicitly allowed preferences. Missing portable settings
  mean Pi defaults, so stale remote preferences are removed.
- Local extensions, skills, themes, prompts, child-agent templates and system
  prompt, compaction/styling configuration, Cloak rules, and keybindings.
- The shared `find-skills` skill. Rex's generated skill/hooks remain Rex-owned;
  install those with `rex skill setup` once per account on each machine.

`lastChangelogVersion` and nonportable settings (for example shell paths) remain
machine-local. The allowlist is in `scripts/sync-pi-config.py`; new settings or
resource categories need deliberate review before joining the baseline.

Changed files are backed up under
`~/.local/state/dotfiles/pi-config-backups/apply-*/` using their home-relative
paths. A machine-local ownership record tracks applied files. Files later
removed from the baseline are archived on the next apply, **but only if this
tool previously managed them**. Empty nested resource directories are pruned
after archival, but directories containing unmanaged files are preserved.
Unmanaged files are never deleted.

## Intentional differences

The VPS retains its extra skills, Git identity preflight extension, standing
`AGENTS.md` instructions, MCP integration/state, and local memory configuration.
These are machine-specific overlays, not permission to copy them back to the
Mac. Existing work profiles remain independent and are not synchronized. The
VPS's retired Inbox/Plannotator services are not installed or enabled. Its
Plannotator skill is explicitly excluded too:

```sh
./dot pi config apply --apply --exclude .pi/agent/skills/plannotator-tui
```

`--exclude` prefixes are saved in that machine's ownership record and shown by
future apply/check commands. They are not captured into the Mac baseline. To
replace an exclusion list, pass the desired complete list of `--exclude` flags;
to clear it entirely, remove only `excludes` from the local ownership record.

Therefore a passing check means **the portable personal baseline matches**,
not that every agent capability or integration on both machines is identical.

## Verification

```sh
python3 scripts/tests/pi-config.test.py
bash -n dot scripts/sync-pi-config.sh scripts/setup-pi-agent.sh
./dot pi doctor
```
