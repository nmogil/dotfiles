#!/usr/bin/env bash
# Tests for `./dot update` (scripts/update.sh). Everything runs against
# temporary git repos, a temporary HOME, and a stub `dot` that records which
# subcommands update.sh invokes. No live config, network, Pi, or Rex is used.
# update.sh runs under the same bash as this suite ($BASH), so running the
# suite with /bin/bash on macOS covers bash 3.2.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); [ -f "$OUT" ] && sed 's/^/     | /' "$OUT"; }
die() { printf 'FATAL fixture setup failed: %s\n' "$1" >&2; exit 2; }

# Canonical temp dir: the private repo path must be canonical, and macOS
# mktemp returns /var/... which resolves to /private/var/...
TMP="$(mktemp -d)" || die "mktemp"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)" || die "canonical TMP"
OUT="$TMP/out"

# --- isolated environment -----------------------------------------------------
unset DOTFILES_LOCAL_ENV XDG_CONFIG_HOME NO_COLOR REX_BIN REX_BIN_DIR \
  DOTFILES_PI_CONFIG_DIR DOTFILES_PI_SCAFFOLD_DIR DOTFILES_PRIVATE_REMOTE DOTFILES_REX_OVERLAY_DIR \
  GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE 2>/dev/null || true
export HOME="$TMP/home"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$HOME" "$TMP/bin" "$TMP/gitstub" || die "mkdir"

# --- stubs -------------------------------------------------------------------
# uname: lets a test choose the OS update.sh sees; everything else is real.
REAL_UNAME="$(command -v uname)" || die "uname"
cat > "$TMP/bin/uname" <<EOF || die "uname stub"
#!/bin/sh
if [ "\${1:-}" = -s ] && [ -n "\${STUB_UNAME:-}" ]; then echo "\$STUB_UNAME"; exit 0; fi
exec "$REAL_UNAME" "\$@"
EOF
chmod +x "$TMP/bin/uname" || die "chmod"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/rex" && chmod +x "$TMP/bin/rex" || die "rex stub"
export PATH="$TMP/bin:$PATH"

# git wrapper (on PATH only while update.sh runs): logs every invocation to
# $STUB_GIT_LOG and fails the subcommand named by $STUB_GIT_FAIL.
REAL_GIT="$(command -v git)" || die "git"
cat > "$TMP/gitstub/git" <<EOF || die "git stub"
#!/bin/sh
sub=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in -C|-c) skip=1 ;; -*) ;; *) sub="\$a"; break ;; esac
done
[ -z "\${STUB_GIT_LOG:-}" ] || printf '%s\n' "\$*" >> "\$STUB_GIT_LOG"
if [ -n "\$sub" ] && [ "\$sub" = "\${STUB_GIT_FAIL:-}" ]; then
  echo "fatal: stub \$sub failure" >&2; exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMP/gitstub/git" || die "chmod"

# Stub `dot`: records argv, prints output shaped like the real commands, and
# fails when its argv equals $STUB_FAIL. STUB_DRIFT makes `pi config check`
# report drift; STUB_REX_REPLACE makes the Rex preview report a differing file.
STUB_DOT="$TMP/stub-dot"
cat > "$STUB_DOT" <<'EOF' || die "dot stub"
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
if [ "$*" = "${STUB_FAIL:-}" ]; then
  for i in $(seq 1 30); do echo "noisy line $i"; done
  echo "stub failure for: $*" >&2
  exit 1
fi
if [ "$*" = "pi config check" ] && [ -n "${STUB_DRIFT:-}" ]; then
  echo "drift  .pi/agent/local-edit.ts"
  echo "3 managed files; 1 differ; 0 retired. Unmanaged files preserved."
  exit 1
fi
case "$*" in
  "pi config apply"*|"pi config check")
    echo "Pi CLI: 1.6.0 (baseline 1.6.0)"
    echo "drift  .pi/agent/example.ts"
    echo "3 managed files; 1 differ; 0 retired. Unmanaged files preserved." ;;
  "pi config packages"*) echo "Pi CLI: 1.6.0 (baseline 1.6.0)"; echo "would install npm:example@1.0.0" ;;
  "rex config --apply")
    if [ -n "${STUB_REX_APPLY_DIFFERS:-}" ]; then
      echo "Existing config differs: /x/init.lua. Review first; --force makes backups." >&2; exit 1
    fi
    echo "init.lua: OK"; echo "Rex configuration matches; 0 file(s) installed."
    echo "Run rex config reload to apply the binding without restarting sessions." ;;
  "rex config --check")
    echo "init.lua: OK"; echo "Rex configuration matches; 0 file(s) installed."
    echo "Run rex config reload to apply the binding without restarting sessions." ;;
  "rex config --dry-run")
    echo "Rex config: /x/init.lua"; echo "would install /x/rex-image-paste/init.lua"
    [ -z "${STUB_REX_REPLACE:-}" ] \
      || echo "would replace /x/init.lua (differs; --apply needs --force, which backs it up)"
    echo "No files changed. Use --apply to install; --check to validate the installed copy." ;;
  "rex install --check") echo "rex-safe-upgrade and Pi pane recorder match source." ;;
esac
EOF
chmod +x "$STUB_DOT" || die "chmod"

# --- fixtures ----------------------------------------------------------------
# Any fixture failure aborts the whole suite: a half-built fixture would make
# later assertions meaningless.
git_q() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1 || die "git $*"; }

# Remotes live under an "owner" directory so the default companion-remote rule
# (same owner as the public origin, repo dotfiles-private) applies to them.
PUB_URL="$TMP/remotes/owner/dotfiles.git"
PRIV_URL="$TMP/remotes/owner/dotfiles-private.git"

# new_remote <url> <seed> <populate-fn>: bare origin + seeded content on main.
new_remote() {
  local url="$1" seed="$2" populate="$3"
  git_q init --bare "$url"
  git_q init "$seed"
  (cd "$seed" && "$populate") || die "populate $seed"
  git_q -C "$seed" add -A
  git_q -C "$seed" commit -m init
  git_q -C "$seed" remote add origin "$url"
  git_q -C "$seed" push -u origin main
}
populate_public() {
  mkdir -p scripts/lib \
    && cp "$ROOT/scripts/update.sh" scripts/update.sh \
    && cp "$ROOT/scripts/lib/local-env.sh" scripts/lib/local-env.sh \
    && cp "$STUB_DOT" dot \
    && echo '# fake dotfiles' > README.md
}
populate_private() {
  mkdir -p pi-scaffold pi-config \
    && echo '{}' > pi-scaffold/package.json \
    && echo '{"piVersion":"1.6.0"}' > pi-config/manifest.json \
    && printf 'secret.local\n' > .gitignore
}
# commit_upstream <seed-name> <fn>: run fn in the seed clone, commit, push.
commit_upstream() {
  (cd "$TMP/seed-$1" && "$2") || die "upstream change in $1"
  git_q -C "$TMP/seed-$1" add -A
  git_q -C "$TMP/seed-$1" commit -m "upstream change"
  git_q -C "$TMP/seed-$1" push origin main
}
bump() { echo "$RANDOM" >> CHANGES; }
push_upstream() { commit_upstream "$1" bump; }

write_local_env() {  # write_local_env <lines...>
  printf '%s\n' "$@" > "$HOME/.config/dotfiles/local.env" || die "local.env"
}

fresh() {  # rebuild remotes + clones for one scenario
  rm -rf "$TMP/remotes" "$TMP"/seed-* "$TMP/public" "$TMP/private" "$HOME" || die "cleanup"
  mkdir -p "$TMP/remotes/owner" "$HOME/.local/bin" "$HOME/.config/dotfiles" || die "mkdir"
  new_remote "$PUB_URL" "$TMP/seed-public" populate_public
  new_remote "$PRIV_URL" "$TMP/seed-private" populate_private
  git_q clone "$PUB_URL" "$TMP/public"
  git_q clone "$PRIV_URL" "$TMP/private"
  write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/private/pi-scaffold\""
  printf '#!/bin/sh\n' > "$HOME/.local/bin/rex-safe-upgrade" || die "rex-safe-upgrade"
  : > "$TMP/calls" || die "calls"
  : > "$TMP/gitlog" || die "gitlog"
}

# run_update [args...]: run the copied update.sh from the fake public repo
# under this suite's bash, with the git wrapper on PATH.
run_update() {
  (cd "$TMP/public" && PATH="$TMP/gitstub:$PATH" STUB_LOG="$TMP/calls" STUB_GIT_LOG="$TMP/gitlog" \
    STUB_UNAME="${STUB_UNAME:-Darwin}" REX_BIN="${TEST_REX_BIN-$TMP/bin/rex}" \
    "$BASH" scripts/update.sh "$@") > "$OUT" 2>&1 < /dev/null
  RC=$?
}
has()   { grep -Fq -- "$1" "$OUT"; }
called(){ grep -Fxq -- "$1" "$TMP/calls"; }
count_calls() { grep -Fxc -- "$1" "$TMP/calls"; }
head_of() { git -C "$1" rev-parse HEAD; }
upstream_of() { git -C "$1" rev-parse '@{u}'; }
remote_head() { git --git-dir="$1" rev-parse main; }
show_calls() { printf '     calls:\n'; sed 's/^/       /' "$TMP/calls"; }
# snapshot <repo>: checksum of every file under .git (objects, refs, index,
# FETCH_HEAD, logs) so a test can prove a run wrote nothing to the repo.
snapshot() { (cd "$1/.git" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done); }

# --- 1: help and argument errors ---------------------------------------------
fresh
run_update --help
[ "$RC" = 0 ] && has "Usage: ./dot update" && has "--dry-run" && has "--fetch" && has "--yes" \
  && [ ! -s "$TMP/calls" ] \
  && ok "--help prints usage and runs nothing" || bad "--help prints usage and runs nothing"
run_update --bogus
[ "$RC" = 2 ] && has "unknown argument" && [ ! -s "$TMP/calls" ] \
  && ok "unknown argument exits 2" || bad "unknown argument exits 2"

# --- 2: real run fast-forwards both repos and applies in order -----------------
fresh; push_upstream public; push_upstream private; push_upstream private
run_update
expected_calls="pi config check
pi config apply --apply
pi config packages --apply
pi config check
rex config --dry-run
rex config --apply
rex config --check
rex install --check"
if [ "$RC" = 0 ] && [ "$(head_of "$TMP/public")" = "$(upstream_of "$TMP/public")" ] \
  && [ "$(head_of "$TMP/private")" = "$(upstream_of "$TMP/private")" ] \
  && has "fast-forwarded 1 commit" && has "fast-forwarded 2 commits" \
  && [ "$(cat "$TMP/calls")" = "$expected_calls" ]; then
  ok "real run: pre-check, fast-forward public+private, Pi apply/packages/check, Rex preview/apply/check"
else
  bad "real run: pre-check, fast-forward public+private, Pi apply/packages/check, Rex preview/apply/check"
  show_calls
fi
grep -q -- '--force' "$TMP/calls" && bad "never passes --force" || ok "never passes --force"
if grep -q -- 'merge --ff-only --no-overwrite-ignore --no-autostash --quiet [0-9a-f]\{40\}$' "$TMP/gitlog" \
  && ! grep -Eq '(^| )(pull|stash|reset|rebase)( |$)' "$TMP/gitlog" && ! grep -q -- '--force' "$TMP/gitlog"; then
  ok "fast-forwards the exact fetched commit (merge --ff-only --no-overwrite-ignore); never pull/stash/reset/force"
else
  bad "fast-forwards the exact fetched commit (merge --ff-only --no-overwrite-ignore); never pull/stash/reset/force"
  sed 's/^/       git /' "$TMP/gitlog"
fi
has "✓" && has "Repos" && has "Pi config" && has "Rex" \
  && grep -Eq '^Summary: 8 ok, 0 warnings, 0 failed, 0 skipped' "$OUT" \
  && ok "one line per step with section headers and a summary line" \
  || bad "one line per step with section headers and a summary line"
has "3 managed files; 1 differ" && has "    drift  .pi/agent/example.ts" && ! grep -q '^Pi CLI' "$OUT" \
  && ok "step output is summarized and indented, not dumped raw" \
  || bad "step output is summarized and indented, not dumped raw"
grep -q $'\033' "$OUT" && bad "no color when stdout is not a TTY" || ok "no color when stdout is not a TTY"

# --- 3: dry-run is read-only; --fetch refreshes remote-tracking refs only -----------
fresh; push_upstream public; push_upstream private
before_pub="$(snapshot "$TMP/public")"; before_priv="$(snapshot "$TMP/private")"
run_update --dry-run
if [ "$RC" = 0 ] && [ "$(snapshot "$TMP/public")" = "$before_pub" ] \
  && [ "$(snapshot "$TMP/private")" = "$before_priv" ] \
  && [ ! -e "$TMP/public/.git/FETCH_HEAD" ] && [ ! -e "$TMP/private/.git/FETCH_HEAD" ] \
  && ! grep -Eq '(^| )fetch( |$)' "$TMP/gitlog" && has "cached" && has "up to date"; then
  ok "dry-run does not fetch: no new objects, refs, index writes, or FETCH_HEAD"
else
  bad "dry-run does not fetch: no new objects, refs, index writes, or FETCH_HEAD"
fi
if ! grep -q -- '--apply' "$TMP/calls" && called "pi config apply" \
  && called "pi config packages" && called "pi config check" && called "rex config --dry-run" \
  && has "    would install npm:example@1.0.0" && has "dry run"; then
  ok "dry-run runs previews and read-only checks only (no --apply), with indented preview lines"
else bad "dry-run runs previews and read-only checks only (no --apply), with indented preview lines"; show_calls; fi

fresh; push_upstream public; push_upstream private
git_q -C "$TMP/public" fetch
before_refs="$(git -C "$TMP/private" for-each-ref)"
run_update --dry-run
[ "$RC" = 0 ] && has "dotfiles: 1 commit behind" && has "would fast-forward" \
  && [ "$(git -C "$TMP/private" for-each-ref)" = "$before_refs" ] \
  && [ "$(head_of "$TMP/public")" != "$(upstream_of "$TMP/public")" ] \
  && ok "dry-run computes behind counts from cached remote-tracking refs" \
  || bad "dry-run computes behind counts from cached remote-tracking refs"

fresh; push_upstream public; push_upstream private
before_head="$(head_of "$TMP/private")"
run_update --dry-run --fetch
if [ "$RC" = 0 ] && has "dotfiles: 1 commit behind" && has "dotfiles-private: 1 commit behind" \
  && [ "$(head_of "$TMP/private")" = "$before_head" ] \
  && [ "$(upstream_of "$TMP/private")" = "$(remote_head "$PRIV_URL")" ] \
  && [ -z "$(git -C "$TMP/private" status --porcelain)" ] && ! grep -q -- '--apply' "$TMP/calls"; then
  ok "--dry-run --fetch refreshes remote-tracking refs only; HEAD and worktree untouched"
else bad "--dry-run --fetch refreshes remote-tracking refs only; HEAD and worktree untouched"; fi

# --- 4: fast-forward safety ------------------------------------------------------
fresh; push_upstream private
echo local-edit >> "$TMP/private/pi-config/manifest.json"
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 0 ] && has "! dotfiles-private" && has "uncommitted or untracked changes" \
  && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && grep -q local-edit "$TMP/private/pi-config/manifest.json" \
  && [ -z "$(git -C "$TMP/private" stash list)" ]; then
  ok "dirty repo is skipped with a warning; edits kept; nothing stashed"
else bad "dirty repo is skipped with a warning; edits kept; nothing stashed"; fi

fresh; push_upstream private
echo note > "$TMP/private/untracked-note.txt"
before_priv="$(head_of "$TMP/private")"
run_update
if has "! dotfiles-private" && has "uncommitted or untracked changes" \
  && [ "$(head_of "$TMP/private")" = "$before_priv" ] && [ -f "$TMP/private/untracked-note.txt" ]; then
  ok "untracked (non-ignored) files make a repo dirty"
else bad "untracked (non-ignored) files make a repo dirty"; fi

# An ignored local file that an incoming commit would track must survive.
add_secret() { echo upstream-version > secret.local && git add -f secret.local; }
fresh; commit_upstream private add_secret
echo LOCAL-SECRET > "$TMP/private/secret.local"
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 1 ] && has "✗ dotfiles-private: fast-forward refused" \
  && [ "$(cat "$TMP/private/secret.local")" = LOCAL-SECRET ] \
  && [ "$(head_of "$TMP/private")" = "$before_priv" ] && ! called "pi config apply --apply"; then
  ok "ignored local file colliding with an incoming tracked file survives; update refuses"
else bad "ignored local file colliding with an incoming tracked file survives; update refuses"; fi

fresh; push_upstream private
before_priv="$(head_of "$TMP/private")"
STUB_GIT_FAIL=status run_update
if [ "$RC" = 1 ] && has "could not read git status" && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && ! grep -q ' merge ' "$TMP/gitlog"; then
  ok "git status error fails closed (no merge)"
else bad "git status error fails closed (no merge)"; fi

fresh; push_upstream private
before_priv="$(head_of "$TMP/private")"
STUB_GIT_FAIL=rev-list run_update
if [ "$RC" = 1 ] && has "could not count commits" && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && ! grep -q ' merge ' "$TMP/gitlog"; then
  ok "git rev-list error fails closed (no merge)"
else bad "git rev-list error fails closed (no merge)"; fi

fresh; push_upstream public
git -C "$TMP/public" checkout -q --detach || die "detach"
run_update
has "detached HEAD" && [ "$RC" = 0 ] && ok "detached HEAD is skipped with a warning" \
  || bad "detached HEAD is skipped with a warning"

add_mine() { echo mine > mine.txt; }
fresh; push_upstream private
(cd "$TMP/private" && add_mine) || die "mine"
git_q -C "$TMP/private" add mine.txt
git_q -C "$TMP/private" commit -m mine
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 0 ] && has "diverged" && [ "$(head_of "$TMP/private")" = "$before_priv" ]; then
  ok "diverged repo is skipped with a warning and left untouched"
else bad "diverged repo is skipped with a warning and left untouched"; fi

# --- 5: binding the private repo -------------------------------------------------
fresh
write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/missing/pi-scaffold\""
run_update
[ "$RC" = 0 ] && has "! dotfiles-private" && has "not found" \
  && ok "configured-but-absent private repo is a warning" || bad "configured-but-absent private repo is a warning"
grep -q '^pi config' "$TMP/calls" && bad "no Pi steps without a baseline" \
  || { has "no pi-config baseline" && ok "no Pi steps without a baseline" || bad "no Pi steps without a baseline"; }

fresh; push_upstream private
ln -s "$TMP/private" "$TMP/private-link" || die "symlink"
write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/private-link/pi-scaffold\""
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 0 ] && has "not a canonical path" && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && ! called "pi config apply --apply"; then
  ok "non-canonical (symlinked) private repo path is refused"
else bad "non-canonical (symlinked) private repo path is refused"; show_calls; fi
rm -f "$TMP/private-link"

fresh
write_local_env 'DOTFILES_PI_SCAFFOLD_DIR="private/pi-scaffold"'
run_update
[ "$RC" = 0 ] && has "not an absolute path" && ! called "pi config apply --apply" \
  && ok "relative private repo path is refused" || bad "relative private repo path is refused"

fresh; push_upstream private
mkdir -p "$TMP/elsewhere" || die "mkdir"
git_q -C "$TMP/private" config core.worktree "$TMP/elsewhere"
before_priv="$(head_of "$TMP/private")"
run_update
[ "$RC" = 0 ] && has "not the top of its git checkout" && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && ! called "pi config apply --apply" \
  && ok "private path that is not the git toplevel is refused" || bad "private path that is not the git toplevel is refused"

fresh; push_upstream private
mkdir -p "$TMP/remotes/stranger" || die "mkdir"
git_q clone --bare "$PRIV_URL" "$TMP/remotes/stranger/dotfiles-private.git"
git_q -C "$TMP/private" remote set-url origin "$TMP/remotes/stranger/dotfiles-private.git"
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 0 ] && has "not the expected companion remote" && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && ! called "pi config apply --apply" && ! grep -q "private fetch" "$TMP/gitlog"; then
  ok "private repo with an unexpected remote is skipped (not fetched or merged)"
else bad "private repo with an unexpected remote is skipped (not fetched or merged)"; fi

fresh; push_upstream private
mkdir -p "$TMP/remotes/stranger" || die "mkdir"
git_q clone --bare "$PRIV_URL" "$TMP/remotes/stranger/my-private.git"
git_q -C "$TMP/private" remote set-url origin "$TMP/remotes/stranger/my-private.git"
write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/private/pi-scaffold\"" \
  "DOTFILES_PRIVATE_REMOTE=\"$TMP/remotes/stranger/my-private.git\""
run_update
[ "$RC" = 0 ] && [ "$(head_of "$TMP/private")" = "$(upstream_of "$TMP/private")" ] \
  && has "dotfiles-private: fast-forwarded" && called "pi config apply --apply" \
  && ok "DOTFILES_PRIVATE_REMOTE overrides the expected companion remote" \
  || bad "DOTFILES_PRIVATE_REMOTE overrides the expected companion remote"

fresh; push_upstream public; push_upstream private
(cd "$TMP/public" && PATH="$TMP/gitstub:$PATH" STUB_LOG="$TMP/calls" STUB_UNAME=Darwin REX_BIN="$TMP/bin/rex" \
  GIT_DIR="$TMP/private/.git" GIT_WORK_TREE="$TMP/private" GIT_INDEX_FILE="$TMP/private/.git/index" \
  GIT_CONFIG_PARAMETERS="'core.worktree=$TMP/private'" "$BASH" scripts/update.sh) > "$OUT" 2>&1 < /dev/null
RC=$?
if [ "$RC" = 0 ] && [ "$(head_of "$TMP/public")" = "$(remote_head "$PUB_URL")" ] \
  && [ "$(head_of "$TMP/private")" = "$(remote_head "$PRIV_URL")" ] \
  && [ -z "$(git -C "$TMP/private" status --porcelain)" ] && [ -z "$(git -C "$TMP/public" status --porcelain)" ]; then
  ok "inherited GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE/GIT_CONFIG_PARAMETERS are ignored"
else bad "inherited GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE/GIT_CONFIG_PARAMETERS are ignored"; fi

fresh; push_upstream private
write_local_env "DOTFILES_PI_CONFIG_DIR=\"$TMP/private/pi-config\""
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 0 ] && has "dotfiles-private: not configured" && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && ! called "pi config apply --apply" && has "apply + packages skipped"; then
  ok "private repo is not inferred from DOTFILES_PI_CONFIG_DIR alone; Pi apply is skipped"
else bad "private repo is not inferred from DOTFILES_PI_CONFIG_DIR alone; Pi apply is skipped"; show_calls; fi

# --- 6: writes are gated on repo outcomes ------------------------------------------
fresh; push_upstream private
echo local-edit >> "$TMP/private/pi-config/manifest.json"
run_update
if has "! apply + packages skipped — dotfiles-private not updated" \
  && ! called "pi config apply --apply" && ! called "pi config packages --apply" \
  && [ "$(count_calls "pi config check")" = 2 ] && called "rex config --apply"; then
  ok "skipped private repo skips Pi apply/packages (checks still run); Rex apply without overlay still runs"
else bad "skipped private repo skips Pi apply/packages (checks still run); Rex apply without overlay still runs"; show_calls; fi

fresh; push_upstream public
echo local-edit >> "$TMP/public/README.md"
run_update
if has "! dotfiles: skipped" && has "apply + packages skipped — dotfiles not updated" \
  && has "image paste config apply skipped — dotfiles not updated" \
  && ! grep -q -- '--apply' "$TMP/calls" && called "rex config --check" && called "rex install --check"; then
  ok "skipped public repo skips Pi and Rex applies; read-only checks still run"
else bad "skipped public repo skips Pi and Rex applies; read-only checks still run"; show_calls; fi

add_overlay() { mkdir -p rex && echo 'return {}' > rex/private.lua; }
fresh; commit_upstream private add_overlay
git_q -C "$TMP/private" pull --ff-only
push_upstream private
echo local-edit >> "$TMP/private/pi-config/manifest.json"
run_update
if has "image paste config apply skipped — dotfiles-private not updated" \
  && ! called "rex config --apply" && called "rex config --check"; then
  ok "Rex apply needs the private repo when a private overlay exists"
else bad "Rex apply needs the private repo when a private overlay exists"; show_calls; fi

fresh
git -C "$TMP/private" remote set-url origin "$TMP/remotes/owner/missing/dotfiles-private.git" || die "set-url"
write_local_env "DOTFILES_PI_SCAFFOLD_DIR=\"$TMP/private/pi-scaffold\"" \
  "DOTFILES_PRIVATE_REMOTE=\"$TMP/remotes/owner/missing/dotfiles-private.git\""
run_update
[ "$RC" = 1 ] && has "fetch failed" && ! called "pi config apply --apply" \
  && has "apply + packages skipped — dotfiles-private not updated (fetch failed)" \
  && ok "fetch failure is reported, exits 1, and skips dependent applies" \
  || bad "fetch failure is reported, exits 1, and skips dependent applies"

# After fast-forwarding a new updater, the NEW updater runs the apply phase.
new_updater() {
  printf '%s\n' 'echo "NEW-UPDATER-RAN $*"' > "$TMP/marker" \
    && awk -v m="$(cat "$TMP/marker")" '{print} $0 == "section \"Pi config\"" {print m}' \
      scripts/update.sh > scripts/update.sh.new && mv scripts/update.sh.new scripts/update.sh
}
fresh; commit_upstream public new_updater; push_upstream private
run_update
if [ "$RC" = 0 ] && has "NEW-UPDATER-RAN --internal-apply-phase" \
  && [ "$(grep -c 'fast-forwarded' "$OUT")" = 2 ] && [ "$(grep -c ' fetch' "$TMP/gitlog")" = 2 ] \
  && [ "$(count_calls "pi config apply --apply")" = 1 ] && called "rex config --apply" \
  && [ "$(grep -c '^Pi config' "$OUT")" = 1 ] && grep -Eq '^Summary: 8 ok, 0 warnings' "$OUT"; then
  ok "an upstream change to the updater re-execs the new updater for the apply phase only"
else bad "an upstream change to the updater re-execs the new updater for the apply phase only"; show_calls; fi

# --- 7: uncaptured live Pi changes are protected ----------------------------------
fresh; push_upstream private
STUB_DRIFT=1 run_update
if [ "$RC" = 0 ] && has "may hold uncaptured local changes" && has "./dot pi config capture" \
  && has "--yes" && ! called "pi config apply --apply" && ! called "pi config packages --apply" \
  && [ "$(count_calls "pi config check")" = 2 ] && has "    drift  .pi/agent/local-edit.ts"; then
  ok "pre-update drift skips Pi apply with a review hint"
else bad "pre-update drift skips Pi apply with a review hint"; show_calls; fi

fresh; push_upstream private
STUB_DRIFT=1 run_update --yes
called "pi config apply --apply" && called "pi config packages --apply" \
  && ok "--yes applies despite pre-update drift" || bad "--yes applies despite pre-update drift"

fresh
STUB_DRIFT=1 run_update --dry-run
[ "$RC" = 0 ] && has "a real update would skip apply" && ! grep -q -- '--apply' "$TMP/calls" \
  && ok "dry-run warns that drift would block apply" || bad "dry-run warns that drift would block apply"

# --- 8: Rex replacements need manual review ----------------------------------------
fresh
STUB_REX_REPLACE=1 run_update --dry-run
if [ "$RC" = 0 ] && has "! image paste config: needs manual review (./dot rex config, then --force)" \
  && has "    would replace /x/init.lua" && ! has "would apply"; then
  ok "dry-run reports a differing Rex file as needing manual review"
else bad "dry-run reports a differing Rex file as needing manual review"; fi

fresh
STUB_REX_REPLACE=1 run_update
if [ "$RC" = 0 ] && has "needs manual review (./dot rex config, then --force)" \
  && called "rex config --dry-run" && ! called "rex config --apply"; then
  ok "real run does not apply Rex config when a file needs --force"
else bad "real run does not apply Rex config when a file needs --force"; show_calls; fi

fresh
STUB_REX_APPLY_DIFFERS=1 run_update
if [ "$RC" = 0 ] && has "! image paste config: needs manual review (./dot rex config, then --force) — not applied" \
  && has "    Existing config differs: /x/init.lua" && ! called "rex config --check"; then
  ok "apply refusing a differing Rex file (older preview format) is a review warning, not a failure"
else bad "apply refusing a differing Rex file (older preview format) is a review warning, not a failure"; show_calls; fi

# --- 9: platform handling --------------------------------------------------------
fresh
STUB_UNAME=Linux run_update
if [ "$RC" = 0 ] && has "skipped (Mac only)" && ! grep -q '^rex config' "$TMP/calls" \
  && called "rex install --check"; then
  ok "Linux skips Rex config (Mac only) but still runs rex install --check"
else bad "Linux skips Rex config (Mac only) but still runs rex install --check"; fi

fresh
rm "$HOME/.local/bin/rex-safe-upgrade" || die "rm"
TEST_REX_BIN="" STUB_UNAME=Linux run_update
! grep -q '^rex' "$TMP/calls" && has "not installed" \
  && ok "rex install check is skipped when rex-safe-upgrade is not installed" \
  || bad "rex install check is skipped when rex-safe-upgrade is not installed"

# --- 10: failures ------------------------------------------------------------------
fresh
STUB_FAIL="pi config packages --apply" run_update
if [ "$RC" = 1 ] && has "✗" && has "    stub failure for: pi config packages --apply" \
  && ! grep -Fxq "    noisy line 1" "$OUT" && has "earlier lines omitted" && grep -Eq '^Summary: .*1 failed' "$OUT"; then
  ok "failed step prints ✗ with an indented output tail and exits 1"
else bad "failed step prints ✗ with an indented output tail and exits 1"; fi

fresh
STUB_FAIL="pi config apply --apply" run_update
! called "pi config packages --apply" && [ "$(count_calls "pi config check")" = 1 ] && [ "$RC" = 1 ] \
  && ok "Pi packages/check are skipped after a failed apply" \
  || bad "Pi packages/check are skipped after a failed apply"

# --- 11: color only on a TTY and never with NO_COLOR ---------------------------------
fresh
pty_run() {
  (cd "$TMP/public" && STUB_LOG="$TMP/calls" STUB_UNAME=Darwin REX_BIN="$TMP/bin/rex" TERM=xterm \
    python3 "$TMP/pty-run.py" "$BASH" scripts/update.sh --dry-run) > "$OUT" 2>&1 < /dev/null
  RC=$?
}
# Run a command on a pseudo-terminal and copy its output (pty.spawn hangs at
# EOF on macOS Python 3.9, so read until EOF/EIO explicitly).
cat > "$TMP/pty-run.py" <<'PY' || die "pty helper"
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    sys.stdout.buffer.write(chunk)
sys.stdout.flush()
_, status = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
PY
pty_run
[ "$RC" = 0 ] && grep -q $'\033\[' "$OUT" && ok "color on a TTY" || bad "color on a TTY"
NO_COLOR=1 pty_run
[ "$RC" = 0 ] && has "Summary:" && ! grep -q $'\033\[' "$OUT" \
  && ok "NO_COLOR disables color on a TTY" || bad "NO_COLOR disables color on a TTY"

# --- 12: the real `dot` dispatches to update.sh --------------------------------------
"$ROOT/dot" update --help > "$OUT" 2>&1 && has "Usage: ./dot update" \
  && ok "./dot update dispatches to scripts/update.sh" || bad "./dot update dispatches to scripts/update.sh"
"$ROOT/dot" help > "$OUT" 2>&1 && has "update" && grep -Eq '^  update ' "$OUT" \
  && ok "./dot help lists update" || bad "./dot help lists update"

printf '\n== update tests: %d pass, %d fail ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
