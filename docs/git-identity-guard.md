# Remote-scoped Git identity guard

Opt-in prevention for accidental cross-workstream Git authorship. This is a local
workflow guard, **not a security sandbox or a Vercel authorization check**.

## Install

Requires Git >= 2.36 and Python >= 3.9. The Pi extension also requires Pi's Node
runtime. Copy `config/git-identity.example.json` to a private local policy file,
replace the placeholder name/email/remote prefixes, then run from this checkout:

```bash
./dot git-identity install /absolute/path/to/private-policy.json
./dot pi identity --dry-run
./dot pi identity --apply
./dot pi identity --check
```

`install` explicitly changes local Git configuration. `pi identity` defaults to
dry-run; only `--apply` copies the extension. It honors `PI_CODING_AGENT_DIR`,
defaulting to `~/.pi/agent`, and refuses to replace a divergent extension. This
original public overlay is independent of the private third-party Pi scaffold;
no changes to auth, sessions, settings, or that scaffold are required. Keep its
canonical source in `templates/pi-identity/`, not in multiple divergent copies.

Run `/reload` in already-open Pi sessions for the new preflight command/handler.
The Git hooks take effect immediately, including for already-running agents.

The private installed policy is `~/.config/git/identity-guard.json`. Identities
and private workstream names are never written into the public repository.

## Behavior

- Git conditional `hasconfig:remote.*.url` includes select the identity by remote,
  not cwd. A new clone or linked worktree with a matching remote inherits it.
- Explicitly list HTTPS, SSH, and any custom SSH-host-alias remote prefixes you
  actually use. Unlisted aliases/case variants are not automatically covered.
- The match applies to **any remote**, including an upstream remote on a fork.
  Repositories matching multiple identity rules fail closed.
- `pre-commit` checks effective author and committer emails, including command
  environment, `--author`, and `git -c user.email=...` overrides. It also checks
  that `core.hooksPath` has not replaced the guard.
- `pre-push` checks current effective identity and the author of each pushed
  commit tip, including peeled annotated tags. It does **not** rewrite or audit
  every ancestor commit. Existing third-party authors remain unchanged; pushing
  their commit as a new tip is blocked and needs deliberate human review.
- Existing executable hooks under the common Git directory's `hooks/` directory
  are chained. Their arguments and stdin are preserved. Existing global custom
  hook managers are refused at install; repository-local `core.hooksPath` overrides
  must be integrated separately and are detected by `check`/Pi preflight.
- Matching repos with a conflicting local `user.email` are **blocked**, not
  silently changed. Audit and correct those local settings deliberately.
- Unmatched repositories retain their existing identity and hook routing.
- `user.useConfigOnly=true` prevents Git's guessed defaults, not explicitly
  configured global identities. The actual email checks provide the protection.

Run the read-only check in a repository:

```bash
python3 ~/.local/share/git-identity-guard/guard.py check
```

Pi also provides `/git-identity` and a best-effort early preflight on Bash
commands mentioning Git commit/push/merge/rebase/cherry-pick/am. It checks Pi's
current cwd, not arbitrary shell-parsed `cd`/`git -C` commands; the real Git hooks
check the actual target repository and per-command environment. The preflight is
not a complete shell parser. Keep the existing no-hook-bypass Pi guard enabled.
A user/process can deliberately bypass local hooks or edit this policy; do not
mistake this convenience guard for remote server enforcement.

## Vercel failure triage

Git author email → GitHub author login → Vercel Login Connection → project/team
membership are separate checks. `vercel whoami` is the CLI identity, not proof
of the Git integration's author mapping. Read the failed GitHub status and
Vercel bot comment, then verify the linked Vercel user's membership.

If a correctly attributed GitHub author is denied membership, changing
`vercel.json`, changing between that user's verified emails, or creating empty
retry commits does not fix authorization. Verify the intended account boundary
first. Never grant cross-workstream membership or move another workstream's
GitHub Login Connection to make a deployment pass. A shared GitHub login is
still one identity even when commits use different verified emails. Separate
accounts require a deliberate owner-confirmed mapping and scoped credentials.

### Quarantine an unresolved deployment identity

Set a rule's `push_block_reason` to a nonempty explanation. Omit **both** `name`
and `email` to preserve the repository's existing identity instead of forcing an
unverified one. Reinstall from the private policy: this replaces earlier generated
identity overrides with hook-only routing. Restore any manually changed repo-local
identity settings separately from their backups; never rewrite commit history.

The `pre-push` hook then rejects all pushes from matching repositories (including
tags/deletions) while local commits remain available. `guard.py check-push` and
Pi's `/git-identity` expose that pause; Pi's Bash preflight also blocks commands
mentioning Vercel in a quarantined cwd. This is a convenience guard, not a shell
sandbox: direct API calls, another machine, `--no-verify`, and changing remotes can
bypass it. Git-hosted deployments must remain paused operationally until mapping
is resolved; this tool does not disable remote webhooks or existing CI jobs.

Do not leave a work account as an ambient machine-wide Vercel login. Vercel CLI's
`--global-config /private/workstream/path --scope <verified-team>` selects an
explicit profile. Preserve tokens without printing them, remove the wrong ambient
credential, verify the scoped profile with `whoami`/`teams ls`, and verify the
default CLI is unauthenticated. Profile paths are not an OS-level security boundary.
Clear the quarantine only after the owner confirms distinct identities and the
correct target-team authorization; then verify an exact preview SHA.

## Verification

```bash
python3 scripts/tests/git-identity-guard.test.py -v
bash -n dot scripts/setup-pi-identity.sh
```

The integration suite isolates HOME/system Git config, executes real commits and
local bare-repository pushes, tests author/env/config overrides, linked worktrees,
SSH remotes, original hooks, unrelated repositories, repeat installation, and the
Pi handler calling the actual guard. Node >= 22.6 is needed for the TypeScript
handler test via `--experimental-strip-types`.

## Backups and rollback

The installer creates an owner-only `~/git-identity-backup-*` snapshot of existing
Git config, policy, and runtime files before mutation, and prints its location.
No repository files or history are changed by the installer. Installation is
staged but **not a crash-atomic transaction**; retain the snapshot until verified.

To disable, remove just the identity-guard include from the global Git config and
remove the Pi overlay file after reviewing it. Do not overwrite an entire current
Git config with an older snapshot if other edits happened since installation.
Keep the installed files until all active include references have been removed.
Restore per-repository identity changes separately if you made any during rollout.

No remote membership changes, billing changes, pushes, or deployments happen as
part of installing this guard.
