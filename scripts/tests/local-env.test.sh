#!/usr/bin/env bash
# Focused tests for the local configuration layer (scripts/lib/local-env.sh):
# portable defaults when absent, and overrides when present. No system state is
# touched — everything runs in a temp dir. Exit nonzero on any failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/local-env.sh"

pass=0; fail=0
ok()   { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL %s (got: %s)\n' "$1" "${2:-}"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1: portable defaults with no local.env -------------------------------
(
  # shellcheck source=../lib/local-env.sh
  . "$LIB"
  export DOTFILES_LOCAL_ENV="$TMP/does-not-exist.env"
  unset DOTFILES_REPO_BUCKETS DOTFILES_GIT_NAME DOTFILES_GIT_EMAIL 2>/dev/null || true
  load_local_env && echo "loaded-unexpectedly" || true
  dotfiles_load_config
  echo "$DOTFILES_REPO_BUCKETS"
) > "$TMP/out1" 2>/dev/null
check "default buckets when no local.env" "$(cat "$TMP/out1")" "personal ventures external"

# --- 2: DOTFILES_LOCAL_ENV override path is honored ------------------------
(
  . "$LIB"
  export DOTFILES_LOCAL_ENV="$TMP/custom/local.env"
  dotfiles_local_env_path
) > "$TMP/out2" 2>/dev/null
check "explicit DOTFILES_LOCAL_ENV path" "$(cat "$TMP/out2")" "$TMP/custom/local.env"

# --- 3: XDG-based default path --------------------------------------------
(
  . "$LIB"
  unset DOTFILES_LOCAL_ENV 2>/dev/null || true
  export XDG_CONFIG_HOME="$TMP/xdg"
  dotfiles_local_env_path
) > "$TMP/out3" 2>/dev/null
check "XDG default path" "$(cat "$TMP/out3")" "$TMP/xdg/dotfiles/local.env"

# --- 4: local.env overrides defaults --------------------------------------
cat > "$TMP/local.env" <<'EOF'
DOTFILES_REPO_BUCKETS="personal clientx external"
DOTFILES_GIT_NAME="Test User"
DOTFILES_GIT_EMAIL="test@example.com"
EOF
(
  . "$LIB"
  export DOTFILES_LOCAL_ENV="$TMP/local.env"
  unset DOTFILES_REPO_BUCKETS 2>/dev/null || true
  dotfiles_load_config
  echo "$DOTFILES_REPO_BUCKETS|$DOTFILES_GIT_NAME|$DOTFILES_GIT_EMAIL"
) > "$TMP/out4" 2>/dev/null
check "local.env overrides" "$(cat "$TMP/out4")" "personal clientx external|Test User|test@example.com"

# --- 5: dotfiles_is_bucket membership -------------------------------------
(
  . "$LIB"
  export DOTFILES_LOCAL_ENV="$TMP/does-not-exist.env"
  unset DOTFILES_REPO_BUCKETS 2>/dev/null || true
  dotfiles_load_config
  if dotfiles_is_bucket personal && ! dotfiles_is_bucket notabucket; then
    echo "membership-ok"
  else
    echo "membership-bad"
  fi
) > "$TMP/out5" 2>/dev/null
check "bucket membership check" "$(cat "$TMP/out5")" "membership-ok"

# --- 6: identity written and parseable via `git config --file` ------------
GITCFG="$TMP/xdg2/git/local.gitconfig"
(
  . "$LIB"
  export XDG_CONFIG_HOME="$TMP/xdg2"
  export DOTFILES_GIT_NAME="Id Name" DOTFILES_GIT_EMAIL="id@example.com"
  dotfiles_apply_git_identity
) >/dev/null 2>&1
if command -v git >/dev/null 2>&1; then
  check "git config --file parses name"  "$(git config --file "$GITCFG" user.name  2>/dev/null)" "Id Name"
  check "git config --file parses email" "$(git config --file "$GITCFG" user.email 2>/dev/null)" "id@example.com"
else
  ok "git config --file (skipped: git not present)"; ok "git config --file email (skipped)"
fi

# --- 7: local.gitconfig is written with owner-only permissions ------------
if [ -f "$GITCFG" ]; then
  perms="$(stat -c '%a' "$GITCFG" 2>/dev/null || stat -f '%Lp' "$GITCFG" 2>/dev/null)"
  check "local.gitconfig is 0600" "$perms" "600"
else
  bad "local.gitconfig missing for perms check" "absent"
fi

# --- 8: CR/LF injection in identity is rejected ---------------------------
(
  . "$LIB"
  export XDG_CONFIG_HOME="$TMP/xdg3"
  # Embed a CR + injected config line into the email.
  export DOTFILES_GIT_NAME="Attacker"
  export DOTFILES_GIT_EMAIL="$(printf 'a@b.com\n\tsigningkey = evil')"
  if dotfiles_apply_git_identity; then echo "accepted-bad"; else echo "rejected-rc=$?"; fi
) > "$TMP/out8" 2>/dev/null
check "CR/LF identity rejected" "$(cat "$TMP/out8")" "rejected-rc=2"
check "no file written on injection" "$( [ -f "$TMP/xdg3/git/local.gitconfig" ] && echo present || echo absent )" "absent"

# --- 9: invalid bucket tokens are dropped ---------------------------------
(
  . "$LIB"
  export DOTFILES_LOCAL_ENV="$TMP/does-not-exist.env"
  export DOTFILES_REPO_BUCKETS="personal ../evil a/b glob* . .. good_1"
  dotfiles_load_config
  echo "$DOTFILES_REPO_BUCKETS"
) > "$TMP/out9" 2>/dev/null
check "invalid bucket tokens filtered" "$(cat "$TMP/out9")" "personal good_1"

# --- 10: token validator direct checks ------------------------------------
(
  . "$LIB"
  r=""
  for t in personal good-1 good_1; do dotfiles_is_valid_bucket_token "$t" && r="${r}v" || r="${r}x"; done
  for t in "a/b" "." ".." "glob*" "sp ace" ""; do dotfiles_is_valid_bucket_token "$t" && r="${r}v" || r="${r}x"; done
  echo "$r"
) > "$TMP/out10" 2>/dev/null
check "token validator accepts/rejects correctly" "$(cat "$TMP/out10")" "vvvxxxxxx"

# --- 11: load_local_env preserves caller's allexport (set -a) state --------
(
  . "$LIB"
  export DOTFILES_LOCAL_ENV="$TMP/local.env"   # exists (from test 4)
  set +a
  load_local_env >/dev/null 2>&1
  case "$-" in *a*) echo "allexport-on" ;; *) echo "allexport-off" ;; esac
) > "$TMP/out11a" 2>/dev/null
check "allexport stays off when caller had it off" "$(cat "$TMP/out11a")" "allexport-off"
(
  . "$LIB"
  export DOTFILES_LOCAL_ENV="$TMP/local.env"
  set -a
  load_local_env >/dev/null 2>&1
  case "$-" in *a*) echo "allexport-on" ;; *) echo "allexport-off" ;; esac
  set +a
) > "$TMP/out11b" 2>/dev/null
check "allexport stays on when caller had it on" "$(cat "$TMP/out11b")" "allexport-on"

# --- 12: a failing local.env restores allexport before returning -----------
printf 'false\n' > "$TMP/failing.env"
(
  . "$LIB"
  export DOTFILES_LOCAL_ENV="$TMP/failing.env"
  set +a
  rc=0; load_local_env || rc=$?
  case "$-" in *a*) state="on" ;; *) state="off" ;; esac
  echo "$rc|$state"
) > "$TMP/out12" 2>/dev/null
check "failed local.env restores shell state" "$(cat "$TMP/out12")" "1|off"

# --- 13: Pi work profile has a portable default ----------------------------
(
  . "$LIB"
  export DOTFILES_LOCAL_ENV="$TMP/does-not-exist.env"
  unset DOTFILES_PI_WORK_PROFILE_SLUG 2>/dev/null || true
  dotfiles_load_config
  echo "$DOTFILES_PI_WORK_PROFILE_SLUG"
) > "$TMP/out13" 2>/dev/null
check "default Pi work profile slug" "$(cat "$TMP/out13")" "work"

# --- 14: local Pi work profile slug is loaded -------------------------------
printf '%s\n' 'DOTFILES_PI_WORK_PROFILE_SLUG="clientx"' > "$TMP/pi-profile.env"
(
  . "$LIB"
  export DOTFILES_LOCAL_ENV="$TMP/pi-profile.env"
  unset DOTFILES_PI_WORK_PROFILE_SLUG 2>/dev/null || true
  dotfiles_load_config
  echo "$DOTFILES_PI_WORK_PROFILE_SLUG"
) > "$TMP/out14" 2>/dev/null
check "local Pi work profile slug" "$(cat "$TMP/out14")" "clientx"

# --- 15: invalid Pi work profile slug falls back safely ---------------------
(
  . "$LIB"
  export DOTFILES_LOCAL_ENV="$TMP/does-not-exist.env"
  export DOTFILES_PI_WORK_PROFILE_SLUG="../private"
  dotfiles_load_config
  echo "$DOTFILES_PI_WORK_PROFILE_SLUG"
) > "$TMP/out15" 2>/dev/null
check "invalid Pi work profile slug" "$(cat "$TMP/out15")" "work"

echo "== local-env tests: $pass pass, $fail fail =="
[ "$fail" -eq 0 ]
