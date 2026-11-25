#!/usr/bin/env bash
# dot update — bring this machine up to date in one command:
#   1. fast-forward the public and private dotfiles repos (git pull --ff-only)
#   2. apply the private Pi baseline, its packages, then check it
#   3. apply + check the Mac Rex image-paste config (Mac only)
#   4. run cheap read-only checks (rex-safe-upgrade install)
#
# Never stashes, resets, or forces; never passes --force to installers; never
# restarts Rex, updates the Pi CLI, or touches running agent sessions. Live
# config changes only through the existing `./dot ... --apply` commands.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOT="$ROOT/dot"
# shellcheck source=lib/local-env.sh
. "$ROOT/scripts/lib/local-env.sh"

usage() {
  cat <<'EOF'
Usage: ./dot update [--dry-run] [--help]

Bring this machine up to date:
  Repos      git pull --ff-only the public and private dotfiles repos; a repo
             that is dirty, detached, diverged, or absent is skipped with a
             warning (never stashed, reset, or forced)
  Pi config  ./dot pi config apply --apply, packages --apply, then check
             (only when a pi-config baseline exists)
  Rex        ./dot rex config --apply, then --check (Mac only; never --force,
             never restarts Rex); ./dot rex install --check when installed

  --dry-run  Fetch and report behind/ahead counts, run apply previews and
             read-only checks; change nothing
  -h, --help Show this help

Exit status is 1 if any step failed. Color is used only on a TTY and never
when NO_COLOR is set.
EOF
}

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'dot update: unknown argument: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------------ reporting
if [ -t 1 ] && [ -z "${NO_COLOR+set}" ] && [ "${TERM:-}" != dumb ]; then
  C_OK=$'\033[32m' C_WARN=$'\033[33m' C_FAIL=$'\033[31m'
  C_DIM=$'\033[2m' C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
else
  C_OK='' C_WARN='' C_FAIL='' C_DIM='' C_BOLD='' C_RESET=''
fi
N_OK=0 N_WARN=0 N_FAIL=0 N_SKIP=0
MAX_DETAIL_LINES=15

section() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }
say_ok()   { N_OK=$((N_OK+1));     printf '  %s✓%s %s\n' "$C_OK" "$C_RESET" "$1"; }
say_warn() { N_WARN=$((N_WARN+1)); printf '  %s!%s %s\n' "$C_WARN" "$C_RESET" "$1"; }
say_fail() { N_FAIL=$((N_FAIL+1)); printf '  %s✗%s %s\n' "$C_FAIL" "$C_RESET" "$1"; }
say_skip() { N_SKIP=$((N_SKIP+1)); printf '  %s- %s%s\n' "$C_DIM" "$1" "$C_RESET"; }

# indent: print stdin as indented, dimmed detail lines, capped to the last
# MAX_DETAIL_LINES lines with a note about how many were omitted.
indent() {
  local lines total
  lines="$(cat)"
  [ -n "$lines" ] || return 0
  total="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"
  if [ "$total" -gt "$MAX_DETAIL_LINES" ]; then
    printf '    %s… %d earlier lines omitted%s\n' "$C_DIM" "$((total - MAX_DETAIL_LINES))" "$C_RESET"
    lines="$(printf '%s\n' "$lines" | tail -n "$MAX_DETAIL_LINES")"
  fi
  printf '%s\n' "$lines" | while IFS= read -r line; do
    printf '    %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
  done
}

LOG="$(mktemp "${TMPDIR:-/tmp}/dot-update.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

# Lines in apply/check/preview output that describe a (pending) change. They are
# shown under a successful step; everything else is summarized away.
CHANGE_LINES='^(would |drift |stale |update |archive |install |npm install |Backups:|package drift|extension dependency drift)'

plural() { if [ "$1" = 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi; }

# summary <pick-regex>: one-line summary of $LOG for the step line.
summary() {
  local pick="$1" line changes
  if [ -n "$pick" ]; then
    line="$(grep -E -- "$pick" "$LOG" | tail -n 1)"
    [ -z "$line" ] || { printf '%s' "$line"; return; }
  fi
  changes="$(grep -Ec -- "$CHANGE_LINES" "$LOG")"
  if [ "$changes" -gt 0 ]; then
    if [ "$DRY_RUN" = 1 ]; then plural "$changes" "pending change"; else plural "$changes" change; fi
  elif [ -n "$pick" ]; then
    grep -v '^[[:space:]]*$' "$LOG" | tail -n 1
  else
    printf 'no changes'
  fi
}

# run_step <label> <pick-regex> <say_fail|say_warn> <hint> <command...>
# Runs a command with output captured, prints one ✓/!/✗ line, and shows only
# change lines on success or the output tail on failure. Returns the exit code.
run_step() {
  local label="$1" pick="$2" on_error="$3" hint="$4" rc=0 detail
  shift 4
  "$@" > "$LOG" 2>&1 < /dev/null || rc=$?
  detail="$(summary "$pick")"
  if [ "$rc" -eq 0 ]; then
    say_ok "$label${detail:+ — $detail}"
    grep -E -- "$CHANGE_LINES" "$LOG" | indent
  else
    "$on_error" "$label failed (exit $rc)${hint:+ — $hint}"
    indent < "$LOG"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------- repos
REPOS_BEHIND=0

# update_repo <label> <dir>
update_repo() {
  local label="$1" dir="$2" branch upstream counts ahead behind before after note=""
  if [ ! -e "$dir/.git" ]; then
    say_warn "$label: skipped — not found (no git checkout at $dir)"; return
  fi
  if ! branch="$(git -C "$dir" symbolic-ref -q --short HEAD)"; then
    say_warn "$label: skipped — detached HEAD; check out a branch to update"; return
  fi
  if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    say_warn "$label: skipped — uncommitted changes on $branch; commit or stash them yourself"; return
  fi
  if ! upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    say_warn "$label: skipped — $branch has no upstream branch"; return
  fi
  if ! GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch --quiet > "$LOG" 2>&1 < /dev/null; then
    say_fail "$label: fetch failed"; indent < "$LOG"; return
  fi
  counts="$(git -C "$dir" rev-list --left-right --count 'HEAD...@{u}')"
  ahead="${counts%%[[:space:]]*}"; behind="${counts##*[[:space:]]}"
  [ "$ahead" -eq 0 ] || note=", $(plural "$ahead" "local commit") not pushed"
  if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
    say_warn "$label: skipped — diverged from $upstream ($ahead ahead, $behind behind); reconcile manually"
    return
  fi
  if [ "$behind" -eq 0 ]; then
    say_ok "$label: up to date ($branch$note)"; return
  fi
  REPOS_BEHIND=$((REPOS_BEHIND + 1))
  if [ "$DRY_RUN" = 1 ]; then
    say_ok "$label: $(plural "$behind" commit) behind $upstream — would fast-forward"
    git -C "$dir" log --oneline --no-decorate 'HEAD..@{u}' | indent
    return
  fi
  before="$(git -C "$dir" rev-parse --short HEAD)"
  if ! GIT_TERMINAL_PROMPT=0 git -C "$dir" -c pull.rebase=false pull --ff-only --quiet > "$LOG" 2>&1 < /dev/null; then
    say_fail "$label: git pull --ff-only failed"; indent < "$LOG"; return
  fi
  after="$(git -C "$dir" rev-parse --short HEAD)"
  say_ok "$label: fast-forwarded $(plural "$behind" commit) ($branch $before..$after)"
}

dotfiles_load_config
SCAFFOLD="${DOTFILES_PI_SCAFFOLD_DIR:-}"
BASELINE="${DOTFILES_PI_CONFIG_DIR:-}"
[ -n "$BASELINE" ] || [ -z "$SCAFFOLD" ] || BASELINE="$(dirname "$SCAFFOLD")/pi-config"
PRIVATE=""
if [ -n "$SCAFFOLD" ]; then PRIVATE="$(dirname "$SCAFFOLD")"
elif [ -n "$BASELINE" ]; then PRIVATE="$(dirname "$BASELINE")"; fi
OS="$(uname -s)"

printf '%sdot update%s %s(%s%s)%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$OS" \
  "$([ "$DRY_RUN" = 1 ] && printf ', dry run — fetch only, nothing applied')" "$C_RESET"

section "Repos"
update_repo dotfiles "$ROOT"
if [ -z "$PRIVATE" ]; then
  say_skip "dotfiles-private: not configured (DOTFILES_PI_SCAFFOLD_DIR unset in local.env)"
elif [ "$(cd "$PRIVATE" 2>/dev/null && pwd -P)" = "$(cd "$ROOT" && pwd -P)" ]; then
  say_skip "dotfiles-private: same checkout as the public repo"
else
  update_repo dotfiles-private "$PRIVATE"
fi
if [ "$DRY_RUN" = 1 ] && [ "$REPOS_BEHIND" -gt 0 ]; then
  printf '  %spreviews below use the current checkouts, before fast-forwarding%s\n' "$C_DIM" "$C_RESET"
fi

# -------------------------------------------------------------------- Pi config
# Run from $HOME so no project-level Pi settings are picked up.
dot_in_home() { (cd "$HOME" && "$DOT" "$@"); }

section "Pi config"
if [ -z "$BASELINE" ] || [ ! -f "$BASELINE/manifest.json" ]; then
  say_skip "no pi-config baseline (set DOTFILES_PI_CONFIG_DIR or DOTFILES_PI_SCAFFOLD_DIR)"
elif [ "$DRY_RUN" = 1 ]; then
  run_step "apply (preview)" 'managed files;' say_fail "" dot_in_home pi config apply
  run_step "packages (preview)" '' say_fail "" dot_in_home pi config packages
  run_step "check" 'managed files;' say_warn "drift that ./dot update would apply" dot_in_home pi config check
else
  if run_step "apply" 'managed files;' say_fail "" dot_in_home pi config apply --apply; then
    run_step "packages" '' say_fail "" dot_in_home pi config packages --apply \
      && grep -Eq '^(install|npm install) ' "$LOG" \
      && printf '    %srestart Pi sessions to load package changes%s\n' "$C_DIM" "$C_RESET"
    run_step "check" 'managed files;' say_fail "" dot_in_home pi config check
  else
    say_skip "packages: skipped (apply failed)"
    say_skip "check: skipped (apply failed)"
  fi
fi

# -------------------------------------------------------------------------- Rex
rex_present() {
  [ -n "${REX_BIN:-}" ] && [ -x "$REX_BIN" ] && return 0
  command -v rex >/dev/null 2>&1 && return 0
  [ -n "${REX_BIN_DIR:-}" ] && [ -x "$REX_BIN_DIR/rex" ] && return 0
  [ -x "$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex" ]
}

section "Rex"
if [ "$OS" != Darwin ]; then
  say_skip "image paste config: skipped (Mac only)"
elif ! rex_present; then
  say_skip "image paste config: Rex not installed"
elif [ "$DRY_RUN" = 1 ]; then
  run_step "image paste config (preview)" '' say_fail "" "$DOT" rex config --dry-run
  run_step "image paste config check" '^Rex configuration matches' say_warn \
    "./dot update would apply it" "$DOT" rex config --check
else
  if run_step "image paste config apply" '^Rex configuration matches' say_fail \
    "review the diff; update never uses --force" "$DOT" rex config --apply; then
    run_step "image paste config check" '^Rex configuration matches' say_fail "" "$DOT" rex config --check
  else
    say_skip "image paste config check: skipped (apply failed)"
  fi
fi
if [ -e "$HOME/.local/bin/rex-safe-upgrade" ]; then
  run_step "rex-safe-upgrade check" 'match source' say_warn "run ./dot rex install --apply" \
    "$DOT" rex install --check
else
  say_skip "rex-safe-upgrade: not installed (./dot rex install --apply to opt in)"
fi

# ---------------------------------------------------------------------- summary
if [ "$N_FAIL" -gt 0 ]; then color="$C_FAIL"; elif [ "$N_WARN" -gt 0 ]; then color="$C_WARN"; else color="$C_OK"; fi
printf '\n%sSummary: %d ok, %s, %d failed, %d skipped%s\n' "$color" "$N_OK" \
  "$(plural "$N_WARN" warning)" "$N_FAIL" "$N_SKIP" "$C_RESET"
[ "$N_FAIL" -eq 0 ]
