#!/usr/bin/env bash
# dot update — bring this machine up to date in one command:
#   1. record whether the live Pi config already differs from the current
#      baseline (possible uncaptured local work), before anything changes
#   2. fetch exactly the tracked upstream branch from the verified remote, then
#      fast-forward the public and private dotfiles repos to that fetched commit
#      (git merge --ff-only --no-overwrite-ignore)
#   3. re-verify both checkouts (path, remote, clean tree, HEAD = that commit)
#      and the Pi baseline / Rex overlay provenance, then apply the Pi baseline
#      and its packages and check it
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
  Repos      fetch the tracked upstream branch from its verified remote, then
             fast-forward the public and private dotfiles repos to that commit
             (git merge --ff-only --no-overwrite-ignore). A repo that is dirty
             (including untracked files), detached, diverged, absent, or
             (private) not at a canonical path or not the expected companion
             remote is skipped with a warning — never stashed, reset, or
             forced — and the applies that depend on it are skipped too
  Pi config  ./dot pi config apply --apply, packages --apply, then check
             (needs both repos, and a baseline tracked and clean in the private
             repo). Skipped when the live config already had file drift from
             the pre-update baseline — it may hold uncaptured local changes —
             or when there was no pre-update baseline, unless --yes
  Rex        Mac only: ./dot rex config --apply, then --check (needs the public
             repo, plus the private one when a private overlay exists); files
             that differ need manual review. ./dot rex install --check when
             installed

  --dry-run  Read-only: behind/ahead from the cached remote-tracking refs (no
             fetch), apply previews and read-only checks; writes nothing to the
             repos or temp files (output is kept in memory)
  --fetch    With --dry-run: fetch the tracked upstream branch first, which
             updates only its remote-tracking ref (never branches or worktrees)
  -y, --yes  Apply the Pi baseline even if the live config had file drift or
             there was no pre-update baseline (apply backs up what it replaces)
  -h, --help Show this help

Exit status is 1 if any step failed. Color is used only on a TTY and never
when NO_COLOR is set.
EOF
}

usage_error() { printf 'dot update: %s\n' "$1" >&2; usage >&2; exit 2; }

DRY_RUN=0 FETCH=0 YES=0 APPLY_PHASE=0
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    --fetch) FETCH=1 ;;
    -y|--yes) YES=1 ;;
    # Internal: set by the previous updater after it fast-forwarded a new
    # version of this script. Skip fetching/pulling and run the apply phase.
    # The DOT_UPDATE_* hand-off is re-verified against the checkouts; anything
    # missing or mismatched means "do not apply".
    --internal-apply-phase) APPLY_PHASE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown argument: $arg" ;;
  esac
done
if [ "$APPLY_PHASE" = 1 ] && { [ "$DRY_RUN" = 1 ] || [ "$FETCH" = 1 ]; }; then
  usage_error "--internal-apply-phase cannot be combined with --dry-run or --fetch"
fi
[ "$FETCH" = 0 ] || [ "$DRY_RUN" = 1 ] || usage_error "--fetch only applies to --dry-run (a real update always fetches)"

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

# Command output is kept in memory (LOG), never in files: a dry run writes
# nothing, not even transient temp files.
LOG=""
capture() { LOG="$("$@" 2>&1 < /dev/null)"; }
log_lines() { [ -z "$LOG" ] || printf '%s\n' "$LOG"; }

# Lines in apply/check/preview output that describe a (pending) change. They are
# shown under a successful step; everything else is summarized away.
CHANGE_LINES='^(would |drift |stale |update |archive |install |npm install |Backups:|package drift|extension dependency drift)'

plural() { if [ "$1" = 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi; }

# summary <pick-regex>: one-line summary of $LOG for the step line.
summary() {
  local pick="$1" line changes
  if [ -n "$pick" ]; then
    line="$(log_lines | grep -E -- "$pick" | tail -n 1)"
    [ -z "$line" ] || { printf '%s' "$line"; return; }
  fi
  changes="$(log_lines | grep -Ec -- "$CHANGE_LINES")"
  if [ "$changes" -gt 0 ]; then
    if [ "$DRY_RUN" = 1 ]; then plural "$changes" "pending change"; else plural "$changes" change; fi
  elif [ -n "$pick" ]; then
    log_lines | grep -v '^[[:space:]]*$' | tail -n 1
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
  capture "$@" || rc=$?
  detail="$(summary "$pick")"
  if [ "$rc" -eq 0 ]; then
    say_ok "$label${detail:+ — $detail}"
    log_lines | grep -E -- "$CHANGE_LINES" | indent
  else
    "$on_error" "$label failed (exit $rc)${hint:+ — $hint}"
    log_lines | indent
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

# check_checkout <dir> <expected-remote-key|"">: is <dir> a checkout we may
# update or apply from? Checks shape, not freshness. On success sets CK_BRANCH,
# CK_REMOTE, CK_SRC (upstream branch on the remote), CK_TRACK (its
# remote-tracking ref), and CK_KEY (remote URL key). On failure returns 1 with
# CK_STATE (short reason), CK_MSG (long reason), and CK_SAY (say_warn|say_fail).
check_checkout() {
  local dir="$1" expect="$2" canonical top status merge url
  CK_SAY=say_warn CK_MSG="" CK_STATE=""
  case "$dir" in
    /*) ;;
    *) CK_STATE="bad path" CK_MSG="$dir is not an absolute path"; return 1 ;;
  esac
  if ! canonical="$(cd "$dir" 2>/dev/null && pwd -P)" || [ ! -e "$dir/.git" ]; then
    CK_STATE="not found" CK_MSG="not found (no git checkout at $dir)"; return 1
  fi
  if [ "$canonical" != "$dir" ]; then
    CK_STATE="bad path" CK_MSG="$dir is not a canonical path (resolves to $canonical)"; return 1
  fi
  if ! top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || [ "$top" != "$dir" ]; then
    CK_STATE="not a checkout root" CK_MSG="$dir is not the top of its git checkout"; return 1
  fi
  if ! CK_BRANCH="$(git -C "$dir" symbolic-ref -q --short HEAD)"; then
    CK_STATE="detached HEAD" CK_MSG="detached HEAD; check out a branch to update"; return 1
  fi
  if ! status="$(git -C "$dir" status --porcelain --untracked-files=normal 2>&1)"; then
    CK_SAY=say_fail CK_STATE="git status failed" CK_MSG="could not read git status; not updating"
    LOG="$status"; return 1
  fi
  if [ -n "$status" ]; then
    CK_STATE="uncommitted changes"
    CK_MSG="uncommitted or untracked changes on $CK_BRANCH; commit, stash, or remove them yourself"
    return 1
  fi
  CK_REMOTE="$(git -C "$dir" config --get "branch.$CK_BRANCH.remote" 2>/dev/null)" || CK_REMOTE=""
  merge="$(git -C "$dir" config --get "branch.$CK_BRANCH.merge" 2>/dev/null)" || merge=""
  case "$CK_REMOTE:$merge" in
    :*|.:*|*:) CK_STATE="no upstream" CK_MSG="$CK_BRANCH has no upstream branch on a remote"; return 1 ;;
  esac
  case "$merge" in
    refs/heads/?*) CK_SRC="${merge#refs/heads/}" ;;
    *) CK_STATE="no upstream" CK_MSG="$CK_BRANCH's upstream $merge is not a branch"; return 1 ;;
  esac
  CK_TRACK="refs/remotes/$CK_REMOTE/$CK_SRC"
  url="$(git -C "$dir" remote get-url "$CK_REMOTE" 2>/dev/null)" || url=""
  CK_KEY="$(remote_key "$url")"
  if [ -z "$url" ]; then
    CK_STATE="unexpected remote" CK_MSG="remote $CK_REMOTE has no URL"; return 1
  fi
  if [ -n "$expect" ] && [ "$CK_KEY" != "$expect" ]; then
    CK_STATE="unexpected remote"
    CK_MSG="$CK_REMOTE ($CK_KEY) is not the expected companion remote $expect; set DOTFILES_PRIVATE_REMOTE in local.env if that is intended"
    return 1
  fi
}

# update_repo <label> <dir> [expected-remote-key]
# Sets REPO_STATE to "ok" (up to date, fast-forwarded, or in dry-run would be)
# or a short reason it was not updated; on ok also REPO_COMMIT (HEAD now) and
# REPO_KEY. UPDATER_CHANGED=1 when the fast-forward touched scripts/update.sh
# or dot.
REPO_STATE="" REPO_COMMIT="" REPO_KEY="" UPDATER_CHANGED=0 REPOS_BEHIND=0
repo_fail() { REPO_STATE="$2"; say_fail "$1: $3"; log_lines | indent; }

update_repo() {
  local label="$1" dir="$2" expect="${3:-}" sha counts ahead behind before after note="" upstream
  REPO_STATE="" REPO_COMMIT="" REPO_KEY="" UPDATER_CHANGED=0
  if ! check_checkout "$dir" "$expect"; then
    REPO_STATE="$CK_STATE"
    if [ "$CK_SAY" = say_fail ]; then repo_fail "$label" "$CK_STATE" "$CK_MSG"
    else say_warn "$label: skipped — $CK_MSG"; fi
    return
  fi
  upstream="$CK_REMOTE/$CK_SRC"
  if [ "$DRY_RUN" = 0 ] || [ "$FETCH" = 1 ]; then
    # Exactly one remote and one branch, into exactly one remote-tracking ref:
    # --refmap= ignores configured refspecs (which could force-update local
    # branches); naming the remote ignores fetch.all. A missing source branch
    # fails the fetch.
    if ! capture git -C "$dir" fetch --quiet --no-tags --no-recurse-submodules --no-prune \
      --no-auto-maintenance --refmap= "$CK_REMOTE" "+refs/heads/$CK_SRC:$CK_TRACK"; then
      repo_fail "$label" "fetch failed" "fetch failed"; return
    fi
  fi
  # Everything below uses this exact commit (the one just fetched, or the
  # cached one in a dry run), never a later re-resolution of @{u}.
  if ! sha="$(git -C "$dir" rev-parse --verify --quiet "$CK_TRACK^{commit}" 2>/dev/null)" || [ -z "$sha" ]; then
    if [ "$DRY_RUN" = 1 ] && [ "$FETCH" = 0 ]; then
      REPO_STATE="no cached upstream"
      say_warn "$label: skipped — no cached $CK_TRACK; rerun with --fetch"; return
    fi
    LOG=""; repo_fail "$label" "upstream unreadable" "could not resolve $CK_TRACK; not updating"; return
  fi
  if ! counts="$(git -C "$dir" rev-list --left-right --count "HEAD...$sha" 2>&1)"; then
    LOG="$counts"; repo_fail "$label" "rev-list failed" "could not count commits against $upstream; not updating"; return
  fi
  ahead="$(printf '%s' "$counts" | awk '{print $1}')"
  behind="$(printf '%s' "$counts" | awk '{print $2}')"
  case "$ahead:$behind" in
    *[!0-9:]*|:*|*:) LOG="$counts"; repo_fail "$label" "rev-list failed" "could not count commits against $upstream; not updating"; return ;;
  esac
  [ "$ahead" -eq 0 ] || note=", $(plural "$ahead" "local commit") not pushed"
  if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
    REPO_STATE="diverged"
    say_warn "$label: skipped — diverged from $upstream ($ahead ahead, $behind behind); reconcile manually"
    return
  fi
  before="$(git -C "$dir" rev-parse HEAD)"
  if [ "$behind" -eq 0 ]; then
    REPO_STATE=ok REPO_COMMIT="$before" REPO_KEY="$CK_KEY"
    say_ok "$label: up to date ($CK_BRANCH$note)"; return
  fi
  REPOS_BEHIND=$((REPOS_BEHIND + 1))
  if [ "$DRY_RUN" = 1 ]; then
    REPO_STATE=ok REPO_COMMIT="$before" REPO_KEY="$CK_KEY"
    say_ok "$label: $(plural "$behind" commit) behind $upstream — would fast-forward"
    git -C "$dir" log --oneline --no-decorate "HEAD..$sha" | indent
    return
  fi
  # --no-overwrite-ignore: refuse rather than clobber an ignored local file
  # that the incoming commits start tracking. --no-autostash: never stash.
  if ! capture git -C "$dir" merge --ff-only --no-overwrite-ignore --no-autostash --quiet "$sha"; then
    repo_fail "$label" "fast-forward refused" "fast-forward refused (nothing changed; see below)"; return
  fi
  after="$(git -C "$dir" rev-parse HEAD)"
  if [ "$after" != "$sha" ]; then
    LOG=""; repo_fail "$label" "fast-forward mismatch" "HEAD is not $upstream after fast-forward"; return
  fi
  if [ -n "$(git -C "$dir" diff --name-only "$before" "$after" -- scripts/update.sh dot 2>/dev/null)" ]; then
    UPDATER_CHANGED=1
  fi
  REPO_STATE=ok REPO_COMMIT="$after" REPO_KEY="$CK_KEY"
  say_ok "$label: fast-forwarded $(plural "$behind" commit) ($CK_BRANCH ${before:0:7}..${after:0:7})"
}

# verify_repo <dir> <expected-remote-key|""> <commit> <remote-key>: right
# before applying, the checkout must still be what was verified/updated: same
# shape, same remote, clean, and HEAD exactly <commit>. Sets VERIFY_REASON.
verify_repo() {
  local dir="$1" expect="$2" commit="$3" key="$4" head
  VERIFY_REASON=""
  case "$commit" in
    ''|*[!0-9a-f]*) VERIFY_REASON="no verified commit"; return 1 ;;
  esac
  if ! check_checkout "$dir" "$expect"; then VERIFY_REASON="$CK_STATE"; return 1; fi
  [ -n "$key" ] && [ "$CK_KEY" = "$key" ] || { VERIFY_REASON="remote changed"; return 1; }
  head="$(git -C "$dir" rev-parse --verify HEAD 2>/dev/null)" || head=""
  [ "$head" = "$commit" ] || { VERIFY_REASON="HEAD is not the verified commit"; return 1; }
}

# tree_problem <path> <what>: why <path> is not exactly what the verified
# private commit contains (empty when it is): it must be canonical, inside the
# private repo, tracked, and free of modified, untracked, or ignored files.
tree_problem() {
  local path="$1" what="$2" real rel status
  real="$(cd "$path" 2>/dev/null && pwd -P)" || { printf '%s %s is missing' "$what" "$path"; return; }
  [ "$real" = "$path" ] || { printf '%s %s is not a canonical path' "$what" "$path"; return; }
  case "$path/" in
    "$PRIVATE"/?*) ;;
    *) printf '%s %s is outside the private repo %s' "$what" "$path" "$PRIVATE"; return ;;
  esac
  rel="${path#"$PRIVATE"/}"
  if [ -z "$(git -C "$PRIVATE" --literal-pathspecs ls-files -- "$rel" 2>/dev/null | head -n 1)" ]; then
    printf '%s %s is not tracked in the private repo' "$what" "$path"; return
  fi
  if ! status="$(git -C "$PRIVATE" --literal-pathspecs status --porcelain --ignored \
    --untracked-files=all -- "$rel" 2>/dev/null)"; then
    printf 'could not read git status for %s %s' "$what" "$path"; return
  fi
  [ -z "$status" ] || printf '%s %s has untracked, ignored, or modified files' "$what" "$path"
}

dotfiles_load_config
SCAFFOLD="${DOTFILES_PI_SCAFFOLD_DIR:-}"
# The private companion is the parent of DOTFILES_PI_SCAFFOLD_DIR — never
# inferred from DOTFILES_PI_CONFIG_DIR, which may point anywhere.
PRIVATE=""
[ -z "$SCAFFOLD" ] || PRIVATE="$(dirname "$SCAFFOLD")"

# abs_from_home <path>: Pi and Rex commands run from $HOME (and
# scripts/sync-pi-config.sh passes the path through unchanged), so relative
# paths are relative to $HOME. Canonical when the path exists.
abs_from_home() {
  local p="$1" real
  [ -n "$p" ] || return 0
  case "$p" in /*) ;; *) p="$HOME/$p" ;; esac
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  if real="$(cd "$p" 2>/dev/null && pwd -P)"; then p="$real"; fi
  printf '%s\n' "$p"
}
# The Pi baseline, resolved ONCE (same defaulting as scripts/sync-pi-config.sh)
# and passed to every Pi command explicitly.
BUNDLE="${DOTFILES_PI_CONFIG_DIR:-}"
[ -n "$BUNDLE" ] || [ -z "$PRIVATE" ] || BUNDLE="$PRIVATE/pi-config"
BUNDLE="$(abs_from_home "$BUNDLE")"
# The private Rex overlay, resolved like scripts/setup-rex-config.sh does.
OVERLAY="${DOTFILES_REX_OVERLAY_DIR:-}"
[ -n "$OVERLAY" ] || [ -z "$PRIVATE" ] || OVERLAY="$PRIVATE/rex"
OVERLAY="$(abs_from_home "$OVERLAY")"
OS="$(uname -s)"
has_baseline() { [ -n "$BUNDLE" ] && [ -f "$BUNDLE/manifest.json" ]; }

# expected_private_key: the companion remote the private repo must track.
expected_private_key() {
  local public_url key
  if [ -n "${DOTFILES_PRIVATE_REMOTE:-}" ]; then remote_key "$DOTFILES_PRIVATE_REMOTE"; return; fi
  public_url="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" || return 0
  [ -n "$public_url" ] || return 0
  key="$(remote_key "$public_url")"
  printf '%s/dotfiles-private\n' "${key%/*}"
}
PRIVATE_EXPECT="$(expected_private_key)"

# Child commands get the resolved paths and must not re-derive them: local.env
# was already loaded (and exported) here, so they skip re-sourcing it.
in_home() { (cd "$HOME" && DOTFILES_LOCAL_ENV=/dev/null "$@"); }
pi_config() { in_home env DOTFILES_PI_CONFIG_DIR="$BUNDLE" "$DOT" pi config "$@"; }
rex_config() { in_home env DOTFILES_REX_OVERLAY_DIR="$OVERLAY" "$DOT" rex config "$@"; }

# classify_check <rc>: classify `pi config check` output in $LOG as clean,
# files (file drift: differing or retired managed files), packages
# (package/dependency drift only), or error (the check did not complete).
classify_check() {
  if [ "$1" = 0 ]; then echo clean; return; fi
  if [ "$1" = 1 ] && log_lines | grep -Eq '^[0-9]+ managed files; [0-9]+ differ; [0-9]+ retired\.'; then
    if log_lines | grep -Eq '^(drift|stale) '; then echo files; else echo packages; fi
  else
    echo error
  fi
}

HANDOFF_OK=1
if [ "$APPLY_PHASE" = 1 ]; then
  # Continue the previous updater's run. Its state is a claim, not proof:
  # every "ok" is re-verified against the checkouts below.
  PUBLIC_STATE="${DOT_UPDATE_PUBLIC:-}" PUBLIC_DIR="${DOT_UPDATE_PUBLIC_DIR:-}"
  PUBLIC_COMMIT="${DOT_UPDATE_PUBLIC_COMMIT:-}" PUBLIC_KEY="${DOT_UPDATE_PUBLIC_REMOTE:-}"
  PRIVATE_STATE="${DOT_UPDATE_PRIVATE:-}" PRIVATE_DIR="${DOT_UPDATE_PRIVATE_DIR:-}"
  PRIVATE_COMMIT="${DOT_UPDATE_PRIVATE_COMMIT:-}" PRIVATE_KEY="${DOT_UPDATE_PRIVATE_REMOTE:-}"
  PI_PRECHECK="${DOT_UPDATE_PI_PRECHECK:-}" PRECHECK_LOG="${DOT_UPDATE_PI_PRECHECK_DETAIL:-}"
  counts="${DOT_UPDATE_COUNTS:-}"
  [ -n "$PUBLIC_STATE" ] && [ -n "$PRIVATE_STATE" ] || HANDOFF_OK=0
  case "$PI_PRECHECK" in clean|files|packages|error|none) ;; *) HANDOFF_OK=0 ;; esac
  [ "${DOT_UPDATE_BUNDLE-unset}" = "$BUNDLE" ] || HANDOFF_OK=0
  if [ "$PUBLIC_STATE" = ok ] && [ "$PUBLIC_DIR" != "$ROOT" ]; then
    PUBLIC_STATE="not verified: checkout path mismatch"
  fi
  if [ "$PRIVATE_STATE" = ok ] && { [ -z "$PRIVATE" ] || [ "$PRIVATE_DIR" != "$PRIVATE" ]; }; then
    PRIVATE_STATE="not verified: checkout path mismatch"
  fi
  set_counts() { [ "$#" = 4 ] && N_OK="$1" N_WARN="$2" N_FAIL="$3" N_SKIP="$4"; }
  case "$counts" in
    *[!0-9\ ]*|'') HANDOFF_OK=0 ;;
    *) # shellcheck disable=SC2086 # deliberately split "ok warn fail skip"
       set_counts $counts || HANDOFF_OK=0 ;;
  esac
  unset DOT_UPDATE_PUBLIC DOT_UPDATE_PUBLIC_DIR DOT_UPDATE_PUBLIC_COMMIT DOT_UPDATE_PUBLIC_REMOTE \
    DOT_UPDATE_PRIVATE DOT_UPDATE_PRIVATE_DIR DOT_UPDATE_PRIVATE_COMMIT DOT_UPDATE_PRIVATE_REMOTE \
    DOT_UPDATE_PI_PRECHECK DOT_UPDATE_PI_PRECHECK_DETAIL DOT_UPDATE_BUNDLE DOT_UPDATE_COUNTS
  if [ "$HANDOFF_OK" = 0 ]; then
    say_fail "updater hand-off state is missing or invalid; not applying anything"
    [ "$PUBLIC_STATE" != ok ] || PUBLIC_STATE="hand-off invalid"
    [ "$PRIVATE_STATE" != ok ] || PRIVATE_STATE="hand-off invalid"
  fi
else
  if [ "$DRY_RUN" = 1 ] && [ "$FETCH" = 1 ]; then mode=', dry run — fetch only, nothing applied'
  elif [ "$DRY_RUN" = 1 ]; then mode=', dry run — read-only, no fetch'
  else mode=''; fi
  printf '%sdot update%s %s(%s%s)%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$OS" "$mode" "$C_RESET"

  # Before anything changes: does the live config already differ from the
  # CURRENT baseline? File drift may be local work nobody has captured, and
  # applying the (new) baseline would overwrite it.
  PI_PRECHECK=none PRECHECK_LOG=""
  if [ "$DRY_RUN" = 0 ] && has_baseline; then
    rc=0; capture pi_config check || rc=$?
    PI_PRECHECK="$(classify_check "$rc")" PRECHECK_RC="$rc" PRECHECK_LOG="$LOG"
  fi

  section "Repos"
  update_repo dotfiles "$ROOT"
  PUBLIC_STATE="$REPO_STATE" PUBLIC_DIR="$ROOT" PUBLIC_COMMIT="$REPO_COMMIT" PUBLIC_KEY="$REPO_KEY"
  PUBLIC_UPDATER_CHANGED="$UPDATER_CHANGED"

  PRIVATE_DIR="$PRIVATE" PRIVATE_COMMIT="" PRIVATE_KEY=""
  if [ -z "$PRIVATE" ]; then
    PRIVATE_STATE="not configured"
    say_skip "dotfiles-private: not configured (DOTFILES_PI_SCAFFOLD_DIR unset in local.env)"
  elif [ -z "$PRIVATE_EXPECT" ]; then
    PRIVATE_STATE="unexpected remote"
    say_warn "dotfiles-private: skipped — cannot derive the expected companion remote (public repo has no origin); set DOTFILES_PRIVATE_REMOTE in local.env"
  else
    update_repo dotfiles-private "$PRIVATE" "$PRIVATE_EXPECT"
    PRIVATE_STATE="$REPO_STATE" PRIVATE_COMMIT="$REPO_COMMIT" PRIVATE_KEY="$REPO_KEY"
  fi
  if [ "$DRY_RUN" = 1 ] && [ "$FETCH" = 0 ]; then
    note "behind/ahead use cached remote-tracking refs; add --fetch to refresh them"
  fi
  if [ "$DRY_RUN" = 1 ] && [ "$REPOS_BEHIND" -gt 0 ]; then
    note "previews below use the current checkouts, before fast-forwarding"
  fi

  # The fast-forward replaced this script or dot: run the apply phase with the
  # NEW updater so its logic (not this stale copy's) decides what to apply. It
  # gets the verified paths and commits and re-verifies them itself.
  if [ "$DRY_RUN" = 0 ] && [ "$PUBLIC_STATE" = ok ] && [ "$PUBLIC_UPDATER_CHANGED" = 1 ]; then
    note "the updater changed; continuing with the new version"
    export DOT_UPDATE_PUBLIC="$PUBLIC_STATE" DOT_UPDATE_PUBLIC_DIR="$PUBLIC_DIR" \
      DOT_UPDATE_PUBLIC_COMMIT="$PUBLIC_COMMIT" DOT_UPDATE_PUBLIC_REMOTE="$PUBLIC_KEY" \
      DOT_UPDATE_PRIVATE="$PRIVATE_STATE" DOT_UPDATE_PRIVATE_DIR="$PRIVATE_DIR" \
      DOT_UPDATE_PRIVATE_COMMIT="$PRIVATE_COMMIT" DOT_UPDATE_PRIVATE_REMOTE="$PRIVATE_KEY" \
      DOT_UPDATE_PI_PRECHECK="$PI_PRECHECK" DOT_UPDATE_BUNDLE="$BUNDLE" \
      DOT_UPDATE_COUNTS="$N_OK $N_WARN $N_FAIL $N_SKIP"
    DOT_UPDATE_PI_PRECHECK_DETAIL="$(printf '%s\n' "$PRECHECK_LOG" | tail -n "$MAX_DETAIL_LINES")"
    export DOT_UPDATE_PI_PRECHECK_DETAIL
    next=(--internal-apply-phase)
    [ "$YES" = 0 ] || next+=(--yes)
    exec "${BASH:-bash}" "$ROOT/scripts/update.sh" "${next[@]}"
  fi
fi

# Re-verify every "ok" right before applying anything.
if [ "$PUBLIC_STATE" = ok ] && ! verify_repo "$ROOT" "" "$PUBLIC_COMMIT" "$PUBLIC_KEY"; then
  PUBLIC_STATE="not verified: $VERIFY_REASON"
fi
if [ "$PRIVATE_STATE" = ok ] \
  && ! verify_repo "$PRIVATE" "$PRIVATE_EXPECT" "$PRIVATE_COMMIT" "$PRIVATE_KEY"; then
  PRIVATE_STATE="not verified: $VERIFY_REASON"
fi

# gate_reason <needs-private:0|1>: why an apply that depends on the repos must
# not run (empty when it may).
repo_reason() {
  case "$2" in
    "not verified: "*) printf '%s not verified (%s)' "$1" "${2#not verified: }" ;;
    *) printf '%s not updated (%s)' "$1" "$2" ;;
  esac
}
gate_reason() {
  if [ "$PUBLIC_STATE" != ok ]; then repo_reason dotfiles "$PUBLIC_STATE"
  elif [ "$1" = 1 ] && [ "$PRIVATE_STATE" != ok ]; then repo_reason dotfiles-private "$PRIVATE_STATE"
  fi
}

# -------------------------------------------------------------------- Pi config
section "Pi config"
REVIEW_HINT="review with ./dot pi config apply (preview) or, on the Mac, ./dot pi config capture; --yes applies anyway (with backups)"
if ! has_baseline; then
  say_skip "no pi-config baseline (set DOTFILES_PI_SCAFFOLD_DIR in local.env)"
else
  pi_gate="$(gate_reason 1)"
  [ -n "$pi_gate" ] || pi_gate="$(tree_problem "$BUNDLE" baseline)"
  if [ "$DRY_RUN" = 1 ]; then
    [ -z "$pi_gate" ] || say_warn "apply + packages: a real update would skip them — $pi_gate"
    run_step "apply (preview)" 'managed files;' say_fail "" pi_config apply
    run_step "packages (preview)" '' say_fail "" pi_config packages
    rc=0; capture pi_config check || rc=$?
    case "$(classify_check "$rc")" in
      clean) say_ok "check — $(summary 'managed files;')"; log_lines | grep -E -- "$CHANGE_LINES" | indent ;;
      packages)
        say_warn "check failed (exit $rc) — package/dependency drift only; ./dot update would install packages"
        log_lines | grep -E -- "$CHANGE_LINES" | indent ;;
      files)
        if [ "$YES" = 1 ]; then hint="./dot update --yes would apply it"
        else hint="live config has file drift from the current baseline, so a real update would skip apply (it may hold uncaptured local changes); $REVIEW_HINT"; fi
        say_warn "check failed (exit $rc) — $hint"; log_lines | indent ;;
      *) say_warn "check failed (exit $rc) — operational error, so a real update would skip apply"; log_lines | indent ;;
    esac
  elif [ -n "$pi_gate" ]; then
    say_warn "apply + packages skipped — $pi_gate"
    run_step "check" 'managed files;' say_warn "" pi_config check
  else
    blocked=""
    case "$PI_PRECHECK" in
      clean) ;;
      packages) note "pre-update check: package/dependency drift only; applying" ;;
      files)
        [ "$YES" = 1 ] || blocked="live config already had file drift from the pre-update baseline and may hold uncaptured local changes; $REVIEW_HINT" ;;
      error)
        say_warn "pre-update check failed (exit ${PRECHECK_RC:-?}) — operational error, so file drift is unknown"
        printf '%s\n' "$PRECHECK_LOG" | indent
        [ "$YES" = 1 ] || blocked="pre-update check did not complete; fix it and rerun, or --yes applies anyway (with backups)" ;;
      none)
        if [ "$YES" = 0 ] && [ -e "$HOME/.pi/agent" ]; then
          blocked="no pre-update baseline to compare the live Pi config against; $REVIEW_HINT"
        fi ;;
      *) blocked="pre-update check state unknown" ;;
    esac
    if [ -n "$blocked" ]; then
      say_warn "apply + packages skipped — $blocked"
      [ "$PI_PRECHECK" != files ] || printf '%s\n' "$PRECHECK_LOG" | grep -E -- '^(drift|stale) ' | indent
      run_step "check" 'managed files;' say_warn "" pi_config check
    # apply backs up every file it replaces. If packages then fails, Pi is left
    # partially applied (new files, old packages); rerun after fixing.
    elif run_step "apply" 'managed files;' say_fail "" pi_config apply --apply; then
      run_step "packages" '' say_fail "Pi config is applied but packages are not; fix and rerun" \
        pi_config packages --apply \
        && log_lines | grep -Eq '^(install|npm install) ' \
        && note "  restart Pi sessions to load package changes"
      run_step "check" 'managed files;' say_fail "" pi_config check
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

# rex_preview: run `rex config --dry-run` into $LOG. Returns its exit code;
# REX_REPLACE is the number of existing files that differ (apply would need
# --force), REX_INSTALL the number of files it would install fresh.
REPLACE_LINES='^would replace '
rex_preview() {
  local rc=0
  capture rex_config --dry-run || rc=$?
  REX_REPLACE="$(log_lines | grep -Ec -- "$REPLACE_LINES")"
  REX_INSTALL="$(log_lines | grep -Ec -- '^would install ')"
  return "$rc"
}
REVIEW_MSG="image paste config: needs manual review (./dot rex config, then --force)"

section "Rex"
if [ "$OS" != Darwin ]; then
  say_skip "image paste config: skipped (Mac only)"
elif ! rex_present; then
  say_skip "image paste config: Rex not installed"
else
  # A private overlay is installed alongside the public config, so it must come
  # from the verified private commit too.
  rex_gate=""
  if [ -n "$OVERLAY" ] && [ -e "$OVERLAY" ]; then
    rex_gate="$(gate_reason 1)"
    [ -n "$rex_gate" ] || rex_gate="$(tree_problem "$OVERLAY" overlay)"
  else
    rex_gate="$(gate_reason 0)"
  fi
  if [ "$DRY_RUN" = 1 ]; then
    [ -z "$rex_gate" ] || say_warn "image paste config: a real update would skip apply — $rex_gate"
    if ! rex_preview; then
      say_fail "image paste config (preview) failed"; log_lines | indent
    elif [ "$REX_REPLACE" -gt 0 ]; then
      say_warn "$REVIEW_MSG — update will not replace $(plural "$REX_REPLACE" "differing file")"
      log_lines | grep -E -- "$CHANGE_LINES" | indent
    else
      if [ "$REX_INSTALL" -gt 0 ]; then say_ok "image paste config (preview) — $(plural "$REX_INSTALL" "pending install")"
      else say_ok "image paste config (preview) — no changes"; fi
      log_lines | grep -E -- "$CHANGE_LINES" | indent
      run_step "image paste config check" '^Rex configuration matches' say_warn \
        "./dot update would install it" rex_config --check
    fi
  elif [ -n "$rex_gate" ]; then
    say_warn "image paste config apply skipped — $rex_gate"
    run_step "image paste config check" '^Rex configuration matches' say_warn "" rex_config --check
  elif ! rex_preview; then
    say_fail "image paste config preview failed"; log_lines | indent
  elif [ "$REX_REPLACE" -gt 0 ]; then
    say_warn "$REVIEW_MSG — not applied; $(plural "$REX_REPLACE" "file") would need --force"
    log_lines | grep -E -- "$REPLACE_LINES" | indent
  elif capture rex_config --apply; then
    say_ok "image paste config apply — $(summary '^Rex configuration matches')"
    log_lines | grep -E -- "$CHANGE_LINES" | indent
    run_step "image paste config check" '^Rex configuration matches' say_fail "" rex_config --check
  elif log_lines | grep -q '^Existing config differs'; then
    # A file changed between preview and apply; the installer refused before
    # copying anything.
    say_warn "$REVIEW_MSG — not applied"
    log_lines | grep '^Existing config differs' | indent
  else
    say_fail "image paste config apply failed — review the diff; update never uses --force"
    log_lines | indent
    say_skip "image paste config check: skipped (apply failed)"
  fi
fi
if [ -e "$HOME/.local/bin/rex-safe-upgrade" ]; then
  run_step "rex-safe-upgrade check" 'match source' say_warn "run ./dot rex install --apply" \
    in_home "$DOT" rex install --check
else
  say_skip "rex-safe-upgrade: not installed (./dot rex install --apply to opt in)"
fi

# ---------------------------------------------------------------------- summary
if [ "$N_FAIL" -gt 0 ]; then color="$C_FAIL"; elif [ "$N_WARN" -gt 0 ]; then color="$C_WARN"; else color="$C_OK"; fi
printf '\n%sSummary: %d ok, %s, %d failed, %d skipped%s\n' "$color" "$N_OK" \
  "$(plural "$N_WARN" warning)" "$N_FAIL" "$N_SKIP" "$C_RESET"
[ "$N_FAIL" -eq 0 ]
