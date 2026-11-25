#!/usr/bin/env bash
# dot update — bring this machine up to date in one command:
#   1. record whether the live Pi config already differs from the current
#      baseline (possible uncaptured local work), before anything changes
#   2. fetch, then fast-forward the public and private dotfiles repos to the
#      exact fetched upstream commit (git merge --ff-only --no-overwrite-ignore)
#   3. apply the private Pi baseline and its packages, then check it — only when
#      both repos updated cleanly
#   4. apply + check the Mac Rex image-paste config (Mac only)
#   5. run cheap read-only checks (rex-safe-upgrade install)
#
# Never stashes, resets, or forces; never passes --force to installers; never
# restarts Rex, updates the Pi CLI, or touches running agent sessions. Live
# config changes only through the existing `./dot ... --apply` commands.
#
# local.env is sourced as bash (scripts/lib/local-env.sh), so it must be a file
# you trust; this script does not sandbox it.
set -uo pipefail

# Inherited repository-redirecting git variables would make every `git -C`
# below (and in child commands) act on some other repository. Drop them.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
  GIT_IMPLICIT_WORK_TREE GIT_PREFIX GIT_SHALLOW_FILE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE \
  GIT_NO_REPLACE_OBJECTS
# `git status` may otherwise refresh the index (a repo write, even in --dry-run);
# never prompt for credentials.
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DOT="$ROOT/dot"
# shellcheck source=lib/local-env.sh
. "$ROOT/scripts/lib/local-env.sh"

usage() {
  cat <<'EOF'
Usage: ./dot update [--dry-run [--fetch]] [--yes] [--help]

Bring this machine up to date:
  Repos      fetch, then fast-forward the public and private dotfiles repos to
             the fetched upstream commit (git merge --ff-only
             --no-overwrite-ignore). A repo that is dirty (including untracked
             files), detached, diverged, absent, or (private) not at a
             canonical path or not the expected companion remote is skipped
             with a warning — never stashed, reset, or forced — and the
             applies that depend on it are skipped too
  Pi config  ./dot pi config apply --apply, packages --apply, then check
             (needs both repos). Skipped when the live config already differed
             from the pre-update baseline — it may hold uncaptured local
             changes — unless --yes
  Rex        Mac only: ./dot rex config --apply, then --check (needs the public
             repo, plus the private one when a private overlay exists); files
             that differ need manual review. ./dot rex install --check when
             installed

  --dry-run  Read-only: behind/ahead from the cached remote-tracking refs (no
             fetch), apply previews and read-only checks; writes nothing
  --fetch    With --dry-run: git fetch first, which updates remote-tracking
             refs only (never branches or working trees)
  -y, --yes  Apply the Pi baseline even if the live config already differed
             from it before the update (apply backs up files it replaces)
  -h, --help Show this help

Exit status is 1 if any step failed. Color is used only on a TTY and never
when NO_COLOR is set.
EOF
}

DRY_RUN=0 FETCH=0 YES=0 APPLY_PHASE=0
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    --fetch) FETCH=1 ;;
    -y|--yes) YES=1 ;;
    # Internal: set by the previous updater after it fast-forwarded a new
    # version of this script. Skip fetching/pulling and run the apply phase
    # using the repo outcomes passed in DOT_UPDATE_* (missing = not updated).
    --internal-apply-phase) APPLY_PHASE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'dot update: unknown argument: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done
if [ "$APPLY_PHASE" = 1 ]; then DRY_RUN=0; fi

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
note()     { printf '  %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }

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

# Command output is captured in temp files outside every repo and removed on
# exit (and before re-exec, which skips the EXIT trap).
LOG="$(mktemp "${TMPDIR:-/tmp}/dot-update.XXXXXX")" || exit 1
PRECHECK="$(mktemp "${TMPDIR:-/tmp}/dot-update.XXXXXX")" || { rm -f "$LOG"; exit 1; }
cleanup() { rm -f "$LOG" "$PRECHECK"; }
trap cleanup EXIT

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
# remote_key <url>: host/path form of a git remote URL with credentials, port,
# trailing slash, and .git stripped, so https, ssh, and scp-style URLs for the
# same repository compare equal. Local paths are returned as-is (minus .git).
remote_key() {
  local u="$1" rest authority
  u="${u%/}"; u="${u%.git}"; u="${u%/}"
  case "$u" in
    *://*)
      rest="${u#*://}"
      case "$rest" in */*) ;; *) rest="$rest/" ;; esac
      authority="${rest%%/*}"; authority="${authority##*@}"; authority="${authority%%:*}"
      printf '%s/%s\n' "$authority" "${rest#*/}" ;;
    /*|.*) printf '%s\n' "$u" ;;
    *:*) rest="${u#*@}"; printf '%s/%s\n' "${rest%%:*}" "${rest#*:}" ;;
    *) printf '%s\n' "$u" ;;
  esac
}

# update_repo <label> <dir> [expected-remote-key]
# Sets REPO_STATE to "ok" (up to date, fast-forwarded, or in dry-run would be)
# or a short reason it was not updated, and UPDATER_CHANGED=1 when the
# fast-forward touched scripts/update.sh or dot.
REPO_STATE="" UPDATER_CHANGED=0 REPOS_BEHIND=0
repo_skip() { REPO_STATE="$2"; say_warn "$1: skipped — $3"; }
repo_fail() { REPO_STATE="$2"; say_fail "$1: $3"; indent < "$LOG"; }

update_repo() {
  local label="$1" dir="$2" expect="${3:-}" top branch status remote url key upstream sha counts \
    ahead behind before after note=""
  REPO_STATE="" UPDATER_CHANGED=0
  if [ ! -e "$dir/.git" ]; then
    repo_skip "$label" "not found" "not found (no git checkout at $dir)"; return
  fi
  if ! top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || [ "$top" != "$dir" ]; then
    repo_skip "$label" "not a checkout root" "$dir is not the top of its git checkout"; return
  fi
  if ! branch="$(git -C "$dir" symbolic-ref -q --short HEAD)"; then
    repo_skip "$label" "detached HEAD" "detached HEAD; check out a branch to update"; return
  fi
  if ! status="$(git -C "$dir" status --porcelain --untracked-files=normal 2>"$LOG")"; then
    repo_fail "$label" "git status failed" "could not read git status; not updating"; return
  fi
  if [ -n "$status" ]; then
    repo_skip "$label" "uncommitted changes" \
      "uncommitted or untracked changes on $branch; commit, stash, or remove them yourself"
    return
  fi
  if ! upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    repo_skip "$label" "no upstream" "$branch has no upstream branch"; return
  fi
  if [ -n "$expect" ]; then
    remote="$(git -C "$dir" config --get "branch.$branch.remote" 2>/dev/null)" || remote=""
    url="$(git -C "$dir" remote get-url "$remote" 2>/dev/null)" || url=""
    key="$(remote_key "$url")"
    if [ -z "$url" ] || [ "$key" != "$expect" ]; then
      repo_skip "$label" "unexpected remote" \
        "${remote:-its upstream} (${key:-no URL}) is not the expected companion remote $expect; set DOTFILES_PRIVATE_REMOTE in local.env if that is intended"
      return
    fi
  fi
  if [ "$DRY_RUN" = 0 ] || [ "$FETCH" = 1 ]; then
    if ! git -C "$dir" fetch --quiet > "$LOG" 2>&1 < /dev/null; then
      repo_fail "$label" "fetch failed" "fetch failed"; return
    fi
  fi
  # Everything below uses this exact commit, so the merge cannot pick up
  # anything that arrived after the counts were computed.
  if ! sha="$(git -C "$dir" rev-parse --verify --quiet '@{u}^{commit}' 2>"$LOG")" || [ -z "$sha" ]; then
    repo_fail "$label" "upstream unreadable" "could not resolve $upstream; not updating"; return
  fi
  if ! counts="$(git -C "$dir" rev-list --left-right --count "HEAD...$sha" 2>"$LOG")"; then
    repo_fail "$label" "rev-list failed" "could not count commits against $upstream; not updating"; return
  fi
  ahead="$(printf '%s' "$counts" | awk '{print $1}')"
  behind="$(printf '%s' "$counts" | awk '{print $2}')"
  case "$ahead" in ''|*[!0-9]*) repo_fail "$label" "rev-list failed" "could not count commits against $upstream; not updating"; return ;; esac
  case "$behind" in ''|*[!0-9]*) repo_fail "$label" "rev-list failed" "could not count commits against $upstream; not updating"; return ;; esac
  [ "$ahead" -eq 0 ] || note=", $(plural "$ahead" "local commit") not pushed"
  if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
    repo_skip "$label" "diverged" "diverged from $upstream ($ahead ahead, $behind behind); reconcile manually"
    return
  fi
  if [ "$behind" -eq 0 ]; then
    REPO_STATE=ok; say_ok "$label: up to date ($branch$note)"; return
  fi
  REPOS_BEHIND=$((REPOS_BEHIND + 1))
  if [ "$DRY_RUN" = 1 ]; then
    REPO_STATE=ok
    say_ok "$label: $(plural "$behind" commit) behind $upstream — would fast-forward"
    git -C "$dir" log --oneline --no-decorate "HEAD..$sha" | indent
    return
  fi
  before="$(git -C "$dir" rev-parse HEAD)"
  # --no-overwrite-ignore: refuse rather than clobber an ignored local file
  # that the incoming commits start tracking. --no-autostash: never stash.
  if ! git -C "$dir" merge --ff-only --no-overwrite-ignore --no-autostash --quiet "$sha" \
    > "$LOG" 2>&1 < /dev/null; then
    repo_fail "$label" "fast-forward refused" "fast-forward refused (nothing changed; see below)"; return
  fi
  after="$(git -C "$dir" rev-parse HEAD)"
  if [ "$after" != "$sha" ]; then
    : > "$LOG"; repo_fail "$label" "fast-forward mismatch" "HEAD is not $upstream after fast-forward"; return
  fi
  if [ -n "$(git -C "$dir" diff --name-only "$before" "$after" -- scripts/update.sh dot 2>/dev/null)" ]; then
    UPDATER_CHANGED=1
  fi
  REPO_STATE=ok
  say_ok "$label: fast-forwarded $(plural "$behind" commit) ($branch ${before:0:7}..${after:0:7})"
}

dotfiles_load_config
SCAFFOLD="${DOTFILES_PI_SCAFFOLD_DIR:-}"
# The private companion is the parent of DOTFILES_PI_SCAFFOLD_DIR — never
# inferred from DOTFILES_PI_CONFIG_DIR, which may point anywhere.
PRIVATE=""
[ -z "$SCAFFOLD" ] || PRIVATE="$(dirname "$SCAFFOLD")"
BASELINE="${DOTFILES_PI_CONFIG_DIR:-}"
[ -n "$BASELINE" ] || [ -z "$PRIVATE" ] || BASELINE="$PRIVATE/pi-config"
# Private Rex overlay, resolved the same way as scripts/setup-rex-config.sh.
OVERLAY="${DOTFILES_REX_OVERLAY_DIR:-}"
[ -n "$OVERLAY" ] || [ -z "$PRIVATE" ] || OVERLAY="$PRIVATE/rex"
OS="$(uname -s)"
has_baseline() { [ -n "$BASELINE" ] && [ -f "$BASELINE/manifest.json" ]; }

# Run from $HOME so no project-level Pi settings are picked up.
dot_in_home() { (cd "$HOME" && "$DOT" "$@"); }

if [ "$APPLY_PHASE" = 1 ]; then
  # Continue the previous updater's run with its outcomes and counts.
  PUBLIC_STATE="${DOT_UPDATE_PUBLIC:-state not passed}"
  PRIVATE_STATE="${DOT_UPDATE_PRIVATE:-state not passed}"
  PI_PRECHECK="${DOT_UPDATE_PI_PRECHECK:-unknown}"
  printf '%s\n' "${DOT_UPDATE_PI_PRECHECK_DETAIL:-}" > "$PRECHECK"
  read -r N_OK N_WARN N_FAIL N_SKIP <<EOF
${DOT_UPDATE_COUNTS:-0 0 0 0}
EOF
  for n in "$N_OK" "$N_WARN" "$N_FAIL" "$N_SKIP"; do
    case "$n" in ''|*[!0-9]*) N_OK=0 N_WARN=0 N_FAIL=1 N_SKIP=0; say_fail "invalid state from the previous updater" ;; esac
  done
  unset DOT_UPDATE_PUBLIC DOT_UPDATE_PRIVATE DOT_UPDATE_PI_PRECHECK DOT_UPDATE_PI_PRECHECK_DETAIL DOT_UPDATE_COUNTS
else
  if [ "$DRY_RUN" = 1 ] && [ "$FETCH" = 1 ]; then mode=', dry run — fetch only, nothing applied'
  elif [ "$DRY_RUN" = 1 ]; then mode=', dry run — read-only, no fetch'
  else mode=''; fi
  printf '%sdot update%s %s(%s%s)%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$OS" "$mode" "$C_RESET"

  # Before anything changes: does the live config already differ from the
  # CURRENT baseline? If so it may hold local work nobody has captured, and
  # applying the (new) baseline would overwrite it.
  PI_PRECHECK=none
  if [ "$DRY_RUN" = 0 ] && has_baseline; then
    if dot_in_home pi config check > "$PRECHECK" 2>&1 < /dev/null; then PI_PRECHECK=clean
    else PI_PRECHECK=drift; fi
  fi

  section "Repos"
  update_repo dotfiles "$ROOT"
  PUBLIC_STATE="$REPO_STATE" PUBLIC_UPDATER_CHANGED="$UPDATER_CHANGED"

  if [ -z "$PRIVATE" ]; then
    PRIVATE_STATE="not configured"
    say_skip "dotfiles-private: not configured (DOTFILES_PI_SCAFFOLD_DIR unset in local.env)"
  else
    expected=""
    if [ -n "${DOTFILES_PRIVATE_REMOTE:-}" ]; then
      expected="$(remote_key "$DOTFILES_PRIVATE_REMOTE")"
    elif public_url="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" && [ -n "$public_url" ]; then
      expected="$(remote_key "$public_url")"
      expected="${expected%/*}/dotfiles-private"
    fi
    canonical="$(cd "$PRIVATE" 2>/dev/null && pwd -P)" || canonical=""
    case "$PRIVATE" in
      /*) absolute=1 ;;
      *) absolute=0 ;;
    esac
    if [ "$absolute" = 0 ]; then
      PRIVATE_STATE="bad path"
      say_warn "dotfiles-private: skipped — $PRIVATE is not an absolute path; fix DOTFILES_PI_SCAFFOLD_DIR in local.env"
    elif [ -z "$canonical" ]; then
      PRIVATE_STATE="not found"
      say_warn "dotfiles-private: skipped — not found (no git checkout at $PRIVATE)"
    elif [ "$canonical" != "$PRIVATE" ]; then
      PRIVATE_STATE="bad path"
      say_warn "dotfiles-private: skipped — $PRIVATE is not a canonical path (resolves to $canonical); use that in DOTFILES_PI_SCAFFOLD_DIR"
    elif [ -z "$expected" ]; then
      PRIVATE_STATE="unexpected remote"
      say_warn "dotfiles-private: skipped — cannot derive the expected companion remote (public repo has no origin); set DOTFILES_PRIVATE_REMOTE in local.env"
    else
      update_repo dotfiles-private "$PRIVATE" "$expected"
      PRIVATE_STATE="$REPO_STATE"
    fi
  fi
  if [ "$DRY_RUN" = 1 ] && [ "$FETCH" = 0 ]; then
    note "behind/ahead use cached remote-tracking refs; add --fetch to refresh them"
  fi
  if [ "$DRY_RUN" = 1 ] && [ "$REPOS_BEHIND" -gt 0 ]; then
    note "previews below use the current checkouts, before fast-forwarding"
  fi

  # The fast-forward replaced this script or dot: run the apply phase with the
  # NEW updater so its logic (not this stale copy's) decides what to apply.
  if [ "$DRY_RUN" = 0 ] && [ "$PUBLIC_STATE" = ok ] && [ "$PUBLIC_UPDATER_CHANGED" = 1 ]; then
    note "the updater changed; continuing with the new version"
    export DOT_UPDATE_PUBLIC="$PUBLIC_STATE" DOT_UPDATE_PRIVATE="$PRIVATE_STATE"
    export DOT_UPDATE_PI_PRECHECK="$PI_PRECHECK" DOT_UPDATE_COUNTS="$N_OK $N_WARN $N_FAIL $N_SKIP"
    DOT_UPDATE_PI_PRECHECK_DETAIL="$(grep -E -- "$CHANGE_LINES" "$PRECHECK" | tail -n "$MAX_DETAIL_LINES")"
    export DOT_UPDATE_PI_PRECHECK_DETAIL
    next=(--internal-apply-phase)
    [ "$YES" = 0 ] || next+=(--yes)
    cleanup
    exec "${BASH:-bash}" "$ROOT/scripts/update.sh" "${next[@]}"
  fi
fi

# gate_reason <needs-private:0|1>: why an apply that depends on the repos must
# not run (empty when it may).
gate_reason() {
  if [ "$PUBLIC_STATE" != ok ]; then printf 'dotfiles not updated (%s)' "$PUBLIC_STATE"
  elif [ "$1" = 1 ] && [ "$PRIVATE_STATE" != ok ]; then printf 'dotfiles-private not updated (%s)' "$PRIVATE_STATE"
  fi
}

# -------------------------------------------------------------------- Pi config
section "Pi config"
DRIFT_HINT="review with ./dot pi config apply (preview) or, on the Mac, ./dot pi config capture; --yes applies anyway (with backups)"
if ! has_baseline; then
  say_skip "no pi-config baseline (set DOTFILES_PI_SCAFFOLD_DIR in local.env)"
else
  pi_gate="$(gate_reason 1)"
  if [ -z "$pi_gate" ]; then
    baseline_real="$(cd "$BASELINE" && pwd -P)"
    case "$baseline_real/" in
      "$PRIVATE"/*) ;;
      *) pi_gate="baseline $BASELINE is outside the private repo $PRIVATE" ;;
    esac
  fi
  if [ "$DRY_RUN" = 1 ]; then
    [ -z "$pi_gate" ] || say_warn "apply + packages: a real update would skip them — $pi_gate"
    run_step "apply (preview)" 'managed files;' say_fail "" dot_in_home pi config apply
    run_step "packages (preview)" '' say_fail "" dot_in_home pi config packages
    if [ "$YES" = 1 ]; then drift_note="./dot update --yes would apply it"
    else drift_note="live config differs from the current baseline, so a real update would skip apply (it may hold uncaptured local changes); $DRIFT_HINT"; fi
    run_step "check" 'managed files;' say_warn "$drift_note" dot_in_home pi config check
  elif [ -n "$pi_gate" ]; then
    say_warn "apply + packages skipped — $pi_gate"
    run_step "check" 'managed files;' say_warn "" dot_in_home pi config check
  elif [ "$PI_PRECHECK" != clean ] && [ "$PI_PRECHECK" != none ] && [ "$YES" = 0 ]; then
    say_warn "apply + packages skipped — live config already differed from the pre-update baseline and may hold uncaptured local changes; $DRIFT_HINT"
    grep -E -- "$CHANGE_LINES" "$PRECHECK" | indent
    run_step "check" 'managed files;' say_warn "" dot_in_home pi config check
  else
    # apply backs up every file it replaces. If packages then fails, Pi is left
    # partially applied (new files, old packages); rerun after fixing.
    if run_step "apply" 'managed files;' say_fail "" dot_in_home pi config apply --apply; then
      run_step "packages" '' say_fail "Pi config is applied but packages are not; fix and rerun" \
        dot_in_home pi config packages --apply \
        && grep -Eq '^(install|npm install) ' "$LOG" \
        && note "  restart Pi sessions to load package changes"
      run_step "check" 'managed files;' say_fail "" dot_in_home pi config check
    else
      say_skip "packages: skipped (apply failed)"
      say_skip "check: skipped (apply failed)"
    fi
  fi
fi

# -------------------------------------------------------------------------- Rex
rex_present() {
  [ -n "${REX_BIN:-}" ] && [ -x "$REX_BIN" ] && return 0
  command -v rex >/dev/null 2>&1 && return 0
  [ -n "${REX_BIN_DIR:-}" ] && [ -x "$REX_BIN_DIR/rex" ] && return 0
  [ -x "$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex" ]
}

# rex_preview: run `rex config --dry-run` into $LOG. Returns 0 when it ran;
# REX_REPLACE is the number of existing files that differ (apply would need
# --force), REX_INSTALL the number of files it would install fresh.
REPLACE_LINES='^would replace '
rex_preview() {
  local rc=0
  "$DOT" rex config --dry-run > "$LOG" 2>&1 < /dev/null || rc=$?
  REX_REPLACE="$(grep -Ec -- "$REPLACE_LINES" "$LOG")"
  REX_INSTALL="$(grep -Ec -- '^would install ' "$LOG")"
  return "$rc"
}
REVIEW_MSG="image paste config: needs manual review (./dot rex config, then --force)"

section "Rex"
if [ "$OS" != Darwin ]; then
  say_skip "image paste config: skipped (Mac only)"
elif ! rex_present; then
  say_skip "image paste config: Rex not installed"
else
  rex_needs_private=0
  [ -z "$OVERLAY" ] || [ ! -e "$OVERLAY" ] || rex_needs_private=1
  rex_gate="$(gate_reason "$rex_needs_private")"
  if [ "$DRY_RUN" = 1 ]; then
    [ -z "$rex_gate" ] || say_warn "image paste config: a real update would skip apply — $rex_gate"
    if ! rex_preview; then
      say_fail "image paste config (preview) failed"; indent < "$LOG"
    elif [ "$REX_REPLACE" -gt 0 ]; then
      say_warn "$REVIEW_MSG — update will not replace $(plural "$REX_REPLACE" "differing file")"
      grep -E -- "$CHANGE_LINES" "$LOG" | indent
    else
      if [ "$REX_INSTALL" -gt 0 ]; then say_ok "image paste config (preview) — $(plural "$REX_INSTALL" "pending install")"
      else say_ok "image paste config (preview) — no changes"; fi
      grep -E -- "$CHANGE_LINES" "$LOG" | indent
      run_step "image paste config check" '^Rex configuration matches' say_warn \
        "./dot update would install it" "$DOT" rex config --check
    fi
  elif [ -n "$rex_gate" ]; then
    say_warn "image paste config apply skipped — $rex_gate"
    run_step "image paste config check" '^Rex configuration matches' say_warn "" "$DOT" rex config --check
  elif ! rex_preview; then
    say_fail "image paste config preview failed"; indent < "$LOG"
  elif [ "$REX_REPLACE" -gt 0 ]; then
    say_warn "$REVIEW_MSG — not applied; $(plural "$REX_REPLACE" "file") would need --force"
    grep -E -- "$REPLACE_LINES" "$LOG" | indent
  elif "$DOT" rex config --apply > "$LOG" 2>&1 < /dev/null; then
    say_ok "image paste config apply — $(summary '^Rex configuration matches')"
    grep -E -- "$CHANGE_LINES" "$LOG" | indent
    run_step "image paste config check" '^Rex configuration matches' say_fail "" "$DOT" rex config --check
  elif grep -q '^Existing config differs' "$LOG"; then
    # Installers whose preview does not distinguish replacements still refuse
    # here, before copying anything.
    say_warn "$REVIEW_MSG — not applied"
    grep '^Existing config differs' "$LOG" | indent
  else
    say_fail "image paste config apply failed — review the diff; update never uses --force"
    indent < "$LOG"
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
