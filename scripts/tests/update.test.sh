#!/usr/bin/env bash
# Tests for `./dot update` (scripts/update.sh). Everything runs against
# temporary git repos, a temporary HOME, and a stub `dot` that records which
# subcommands update.sh invokes. No live config, network, Pi, or Rex is used.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); [ -f "$OUT" ] && sed 's/^/     | /' "$OUT"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/out"

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_NOSYSTEM=1
unset NO_COLOR REX_BIN REX_BIN_DIR DOTFILES_PI_CONFIG_DIR DOTFILES_PI_SCAFFOLD_DIR 2>/dev/null || true
mkdir -p "$HOME" "$TMP/bin"

# --- stubs -------------------------------------------------------------------
# uname: lets a test choose the OS update.sh sees; everything else is real.
REAL_UNAME="$(command -v uname)"
cat > "$TMP/bin/uname" <<EOF
#!/bin/sh
if [ "\${1:-}" = -s ] && [ -n "\${STUB_UNAME:-}" ]; then echo "\$STUB_UNAME"; exit 0; fi
exec "$REAL_UNAME" "\$@"
EOF
chmod +x "$TMP/bin/uname"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/rex"; chmod +x "$TMP/bin/rex"
export PATH="$TMP/bin:$PATH"

# Stub `dot`: records argv, prints output shaped like the real commands, and
# fails when its argv equals $STUB_FAIL.
STUB_DOT="$TMP/stub-dot"
cat > "$STUB_DOT" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
if [ "$*" = "${STUB_FAIL:-}" ]; then
  for i in $(seq 1 30); do echo "noisy line $i"; done
  echo "stub failure for: $*" >&2
  exit 1
fi
case "$*" in
  "pi config apply"*|"pi config check")
    echo "Pi CLI: 1.6.0 (baseline 1.6.0)"
    echo "drift  .pi/agent/example.ts"
    echo "3 managed files; 1 differ; 0 retired. Unmanaged files preserved." ;;
  "pi config packages"*) echo "Pi CLI: 1.6.0 (baseline 1.6.0)"; echo "would install npm:example@1.0.0" ;;
  "rex config --check"|"rex config --apply")
    echo "init.lua: OK"; echo "Rex configuration matches; 0 file(s) installed."
    echo "Run rex config reload to apply the binding without restarting sessions." ;;
  "rex config"*) echo "Rex config: /x/init.lua"; echo "would install /x/init.lua" ;;
  "rex install --check") echo "rex-safe-upgrade and Pi pane recorder match source." ;;
esac
EOF
chmod +x "$STUB_DOT"

# --- fixtures ----------------------------------------------------------------
git_q() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# new_remote <name> <populate-fn>: bare origin + seeded content on main.
new_remote() {
  local name="$1" populate="$2" seed="$TMP/seed-$1"
  git_q init --bare "$TMP/remotes/$name.git"
  git_q init "$seed"
  (cd "$seed" && "$populate" && git_q add -A && git_q commit -m init \
    && git_q remote add origin "$TMP/remotes/$name.git" && git_q push -u origin main)
}
populate_public() {
  mkdir -p scripts/lib
  cp "$ROOT/scripts/update.sh" scripts/update.sh
  cp "$ROOT/scripts/lib/local-env.sh" scripts/lib/local-env.sh
  cp "$STUB_DOT" dot
}
populate_private() {
  mkdir -p pi-scaffold pi-config
  echo '{}' > pi-scaffold/package.json
  echo '{"piVersion":"1.6.0"}' > pi-config/manifest.json
}
# push_upstream <name>: add a commit on origin/main from the seed clone.
push_upstream() {
  (cd "$TMP/seed-$1" && echo "$RANDOM" >> CHANGES && git_q add -A \
    && git_q commit -m "upstream $RANDOM" && git_q push origin main)
}

fresh() {  # rebuild remotes + clones for one scenario
  rm -rf "$TMP/remotes" "$TMP"/seed-* "$TMP/public" "$TMP/private" "$HOME"
  mkdir -p "$TMP/remotes" "$HOME/.local/bin" "$HOME/.config/dotfiles"
  new_remote public populate_public
  new_remote private populate_private
  git_q clone "$TMP/remotes/public.git" "$TMP/public"
  git_q clone "$TMP/remotes/private.git" "$TMP/private"
  printf 'DOTFILES_PI_SCAFFOLD_DIR="%s"\n' "$TMP/private/pi-scaffold" > "$HOME/.config/dotfiles/local.env"
  printf '#!/bin/sh\n' > "$HOME/.local/bin/rex-safe-upgrade"
  : > "$TMP/calls"
}

# run_update [args...]: run the copied update.sh from the fake public repo.
run_update() {
  (cd "$TMP/public" && STUB_LOG="$TMP/calls" STUB_UNAME="${STUB_UNAME:-Darwin}" \
    REX_BIN="${TEST_REX_BIN-$TMP/bin/rex}" bash scripts/update.sh "$@") > "$OUT" 2>&1 < /dev/null
  RC=$?
}
has()   { grep -Fq -- "$1" "$OUT"; }
called(){ grep -Fxq -- "$1" "$TMP/calls"; }
head_of() { git -C "$1" rev-parse HEAD; }
upstream_of() { git -C "$1" rev-parse '@{u}'; }

# --- 1: help and argument errors ---------------------------------------------
fresh
run_update --help
[ "$RC" = 0 ] && has "Usage: ./dot update" && has "--dry-run" && [ ! -s "$TMP/calls" ] \
  && ok "--help prints usage and runs nothing" || bad "--help prints usage and runs nothing"
run_update --bogus
[ "$RC" = 2 ] && has "unknown argument" && [ ! -s "$TMP/calls" ] \
  && ok "unknown argument exits 2" || bad "unknown argument exits 2"

# --- 2: real run fast-forwards both repos and applies in order -----------------
fresh; push_upstream public; push_upstream private; push_upstream private
run_update
expected_calls="pi config apply --apply
pi config packages --apply
pi config check
rex config --apply
rex config --check
rex install --check"
if [ "$RC" = 0 ] && [ "$(head_of "$TMP/public")" = "$(upstream_of "$TMP/public")" ] \
  && [ "$(head_of "$TMP/private")" = "$(upstream_of "$TMP/private")" ] \
  && has "fast-forwarded 1 commit" && has "fast-forwarded 2 commits" \
  && [ "$(cat "$TMP/calls")" = "$expected_calls" ]; then
  ok "real run fast-forwards public+private, then Pi apply/packages/check and Rex apply/check"
else
  bad "real run fast-forwards public+private, then Pi apply/packages/check and Rex apply/check"
  printf '     calls:\n'; sed 's/^/       /' "$TMP/calls"
fi
grep -q -- '--force' "$TMP/calls" && bad "never passes --force" || ok "never passes --force"
has "✓" && has "Repos" && has "Pi config" && has "Rex" \
  && grep -Eq '^Summary: 8 ok, 0 warnings, 0 failed, 0 skipped' "$OUT" \
  && ok "one line per step with section headers and a summary line" \
  || bad "one line per step with section headers and a summary line"
has "3 managed files; 1 differ" && has "    drift  .pi/agent/example.ts" && ! grep -q '^Pi CLI' "$OUT" \
  && ok "step output is summarized and indented, not dumped raw" \
  || bad "step output is summarized and indented, not dumped raw"
grep -q $'\033' "$OUT" && bad "no color when stdout is not a TTY" || ok "no color when stdout is not a TTY"

# --- 3: dry-run fetches and previews without writes -----------------------------
fresh; push_upstream public; push_upstream private
before_pub="$(head_of "$TMP/public")"; before_priv="$(head_of "$TMP/private")"
run_update --dry-run
if [ "$RC" = 0 ] && [ "$(head_of "$TMP/public")" = "$before_pub" ] \
  && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && has "1 commit behind" && has "would fast-forward" \
  && ! grep -q -- '--apply' "$TMP/calls" && called "pi config apply" \
  && called "pi config packages" && called "rex config --dry-run"; then
  ok "dry-run reports behind counts and runs previews only (no --apply)"
else
  bad "dry-run reports behind counts and runs previews only (no --apply)"
  printf '     calls:\n'; sed 's/^/       /' "$TMP/calls"
fi
has "    would install npm:example@1.0.0" && has "dry run" \
  && ok "dry-run shows indented preview lines" || bad "dry-run shows indented preview lines"

# --- 4: dirty, detached, diverged, and absent repos are skipped with warnings ---
fresh; push_upstream private
echo local-edit >> "$TMP/private/pi-config/manifest.json"
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 0 ] && has "! dotfiles-private" && has "uncommitted changes" \
  && [ "$(head_of "$TMP/private")" = "$before_priv" ] \
  && grep -q local-edit "$TMP/private/pi-config/manifest.json" \
  && [ -z "$(git -C "$TMP/private" stash list)" ]; then
  ok "dirty repo is skipped with a warning; edits kept; nothing stashed"
else bad "dirty repo is skipped with a warning; edits kept; nothing stashed"; fi

fresh; push_upstream public
git -C "$TMP/public" checkout -q --detach
run_update
has "detached HEAD" && [ "$RC" = 0 ] && ok "detached HEAD is skipped with a warning" \
  || bad "detached HEAD is skipped with a warning"

fresh; push_upstream private
(cd "$TMP/private" && echo mine > mine.txt && git_q add mine.txt && git_q commit -m mine)
before_priv="$(head_of "$TMP/private")"
run_update
if [ "$RC" = 0 ] && has "diverged" && [ "$(head_of "$TMP/private")" = "$before_priv" ]; then
  ok "diverged repo is skipped with a warning and left untouched"
else bad "diverged repo is skipped with a warning and left untouched"; fi

fresh
printf 'DOTFILES_PI_SCAFFOLD_DIR="%s"\n' "$TMP/missing/pi-scaffold" > "$HOME/.config/dotfiles/local.env"
run_update
[ "$RC" = 0 ] && has "! dotfiles-private" && has "not found" \
  && ok "configured-but-absent private repo is a warning" || bad "configured-but-absent private repo is a warning"
grep -q '^pi config' "$TMP/calls" && bad "no Pi steps without a baseline" \
  || { has "no pi-config baseline" && ok "no Pi steps without a baseline" || bad "no Pi steps without a baseline"; }

# --- 5: platform handling --------------------------------------------------------
fresh
STUB_UNAME=Linux run_update
if [ "$RC" = 0 ] && has "skipped (Mac only)" && ! grep -q '^rex config' "$TMP/calls" \
  && called "rex install --check"; then
  ok "Linux skips Rex config (Mac only) but still runs rex install --check"
else bad "Linux skips Rex config (Mac only) but still runs rex install --check"; fi

fresh
rm "$HOME/.local/bin/rex-safe-upgrade"
TEST_REX_BIN="" STUB_UNAME=Linux run_update
! grep -q '^rex' "$TMP/calls" && has "not installed" \
  && ok "rex install check is skipped when rex-safe-upgrade is not installed" \
  || bad "rex install check is skipped when rex-safe-upgrade is not installed"

# --- 6: failures ------------------------------------------------------------------
fresh
STUB_FAIL="pi config check" run_update
if [ "$RC" = 1 ] && has "✗" && has "    stub failure for: pi config check" \
  && ! grep -Fxq "    noisy line 1" "$OUT" && has "earlier lines omitted" && grep -Eq '^Summary: .*1 failed' "$OUT"; then
  ok "failed step prints ✗ with an indented output tail and exits 1"
else bad "failed step prints ✗ with an indented output tail and exits 1"; fi

fresh
STUB_FAIL="pi config apply --apply" run_update
! called "pi config packages --apply" && ! called "pi config check" && [ "$RC" = 1 ] \
  && ok "Pi packages/check are skipped after a failed apply" \
  || bad "Pi packages/check are skipped after a failed apply"

fresh
git -C "$TMP/private" remote set-url origin "$TMP/remotes/nope.git"
run_update
[ "$RC" = 1 ] && has "fetch failed" && ok "fetch failure is reported and exits 1" \
  || bad "fetch failure is reported and exits 1"

# --- 7: color only on a TTY and never with NO_COLOR ---------------------------------
fresh
pty_run() {
  (cd "$TMP/public" && STUB_LOG="$TMP/calls" STUB_UNAME=Darwin REX_BIN="$TMP/bin/rex" TERM=xterm \
    python3 "$TMP/pty-run.py" bash scripts/update.sh --dry-run) > "$OUT" 2>&1 < /dev/null
}
# Run a command on a pseudo-terminal and copy its output (pty.spawn hangs at
# EOF on macOS Python 3.9, so read until EOF/EIO explicitly).
cat > "$TMP/pty-run.py" <<'PY'
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
grep -q $'\033\[' "$OUT" && ok "color on a TTY" || bad "color on a TTY"
NO_COLOR=1 pty_run
grep -q $'\033\[' "$OUT" && bad "NO_COLOR disables color on a TTY" || ok "NO_COLOR disables color on a TTY"

# --- 8: the real `dot` dispatches to update.sh --------------------------------------
"$ROOT/dot" update --help > "$OUT" 2>&1 && has "Usage: ./dot update" \
  && ok "./dot update dispatches to scripts/update.sh" || bad "./dot update dispatches to scripts/update.sh"
"$ROOT/dot" help > "$OUT" 2>&1 && has "update" && grep -Eq '^  update ' "$OUT" \
  && ok "./dot help lists update" || bad "./dot help lists update"

printf '\n== update tests: %d pass, %d fail ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
