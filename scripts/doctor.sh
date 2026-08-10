#!/usr/bin/env bash
# doctor.sh — read-only health check for this dotfiles environment.
# Installs nothing, mutates no system state. Exit 0 on pass/warn; nonzero only
# on hard failures (not in repo root, or a required repo file is missing).
set -uo pipefail

script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

ROOT="$(cd "$(script_dir)/.." && pwd)"
# shellcheck source=lib/local-env.sh
. "$ROOT/scripts/lib/local-env.sh"
dotfiles_load_config

pass=0; warn=0; fail=0
PASS() { printf 'PASS  %s\n' "$*"; pass=$((pass+1)); }
WARN() { printf 'WARN  %s\n' "$*"; warn=$((warn+1)); }
FAIL() { printf 'FAIL  %s\n' "$*"; fail=$((fail+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

echo "== dotfiles doctor =="
echo "repo root: $ROOT"
echo

# --- repo root & required files (hard failures) ---
if [ -f "$ROOT/dot" ] && [ -f "$ROOT/setup.sh" ]; then
  PASS "in dotfiles repo root"
else
  FAIL "not a dotfiles repo root (missing dot/setup.sh)"
fi

required=(setup.sh setup-linux.sh clone-repos.sh harden-vps.sh setup-obsidian-sync.sh \
         Brewfile .zshrc .gitconfig .p10k.zsh .tmux.conf config/hunk/config.toml config/ghostty/config \
         templates/herdr/config.toml templates/herdr/plugins/config/persiyanov.reviewr/config.toml \
         templates/hermes/config.portable.yaml)
for f in "${required[@]}"; do
  if [ -e "$ROOT/$f" ]; then PASS "config present: $f"; else FAIL "missing required file: $f"; fi
done

# --- scripts executable ---
for s in dot setup.sh setup-linux.sh clone-repos.sh harden-vps.sh setup-obsidian-sync.sh scripts/doctor.sh scripts/setup-herdr-config.sh scripts/setup-hermes-config.sh scripts/setup-pi-agent.sh scripts/setup-pi-profiles.sh scripts/setup-pi-subagents.sh scripts/tests/agent-configs.test.sh scripts/tests/local-env.test.sh scripts/tests/pi-git-interceptor.test.sh scripts/tests/pi-profiles.test.sh scripts/tests/pi-scaffold.test.sh scripts/tests/pi-subagents.test.sh; do
  [ -e "$ROOT/$s" ] || continue
  if [ -x "$ROOT/$s" ]; then PASS "executable: $s"; else WARN "not executable: $s (chmod +x $s)"; fi
done

echo
echo "-- os & core tools --"
case "$(uname -s)" in
  Darwin) PASS "OS: macOS"; have brew && PASS "brew present" || WARN "brew missing (run: ./dot setup mac)";;
  Linux)  PASS "OS: Linux"
          if have apt-get; then PASS "apt-get present (Debian/Ubuntu)"; else WARN "apt-get missing (not Debian/Ubuntu?)"; fi;;
  *) WARN "OS: $(uname -s) (untested)";;
esac
have git  && PASS "git present" || FAIL "git missing"
have zsh  && PASS "zsh present" || WARN "zsh missing (shell not configured)"

if have gh; then
  if gh auth status >/dev/null 2>&1; then PASS "gh authenticated"; else WARN "gh present but not authenticated (gh auth login)"; fi
else
  WARN "gh missing (needed for ./dot repos clone)"
fi

echo
echo "-- agent & sync tooling (optional) --"
for tool in chezmoi herdr hermes claude codex hunk ob tailscale pi; do
  if have "$tool"; then PASS "$tool present"; else WARN "$tool missing"; fi
done

if "$ROOT/scripts/setup-herdr-config.sh" --check >/dev/null 2>&1; then
  PASS "Herdr portable config matches"
else
  WARN "Herdr portable config drift (run: ./dot herdr config --apply)"
fi
if "$ROOT/scripts/setup-hermes-config.sh" --check >/dev/null 2>&1; then
  PASS "Hermes portable config matches"
else
  WARN "Hermes portable config drift (run: ./dot hermes config --apply)"
fi

echo
echo "-- repo buckets under \${GITHUB_REPOS_DIR:-\$HOME/github_repos} --"
REPOS_DIR="${GITHUB_REPOS_DIR:-$HOME/github_repos}"
if [ -d "$REPOS_DIR" ]; then
  PASS "repos dir exists: $REPOS_DIR"
  # Report counts only; bucket names may be private codenames — do not log them.
  bucket_total=0; bucket_present=0
  for b in $DOTFILES_REPO_BUCKETS; do
    bucket_total=$((bucket_total+1))
    [ -d "$REPOS_DIR/$b" ] && bucket_present=$((bucket_present+1))
  done
  PASS "workstream buckets present: $bucket_present/$bucket_total (names omitted)"
else
  WARN "repos dir not present: $REPOS_DIR (run: ./dot repos clone)"
fi

echo
echo "-- local configuration --"
LOCAL_ENV_PATH="$(dotfiles_local_env_path)"
if [ -f "$LOCAL_ENV_PATH" ]; then
  PASS "local override present: $LOCAL_ENV_PATH"
else
  WARN "no local override (using portable defaults): $LOCAL_ENV_PATH — see config/dotfiles/local.env.example"
fi
# Count configured buckets without printing their (possibly private) names.
bucket_count=0
for _b in $DOTFILES_REPO_BUCKETS; do bucket_count=$((bucket_count+1)); done
PASS "repo buckets configured: $bucket_count (names omitted; see local.env)"

echo
echo "-- secret hygiene --"
# repos.txt holds a personal repo list; it must not be tracked.
if git -C "$ROOT" ls-files --error-unmatch repos.txt >/dev/null 2>&1; then
  FAIL "repos.txt is tracked by git — remove it (it should stay gitignored)"
else
  PASS "repos.txt not tracked"
fi
# The tracked .gitconfig must not carry a personal identity (kept local).
if grep -qiE '^[[:space:]]*(name|email)[[:space:]]*=' "$ROOT/.gitconfig" 2>/dev/null; then
  FAIL ".gitconfig has a tracked user.name/email — move identity to ~/.config/dotfiles/local.env"
else
  PASS "no tracked git identity in .gitconfig"
fi
# Warn on any tracked env/secret-ish files.
tracked_secrets="$(git -C "$ROOT" ls-files 2>/dev/null | grep -iE '(^|/)\.env|\.env($|\.)|secret|credential|\.pem$|id_rsa' || true)"
if [ -n "$tracked_secrets" ]; then
  WARN "tracked files look secret-sensitive:"; printf '        %s\n' $tracked_secrets
else
  PASS "no obvious secret files tracked"
fi

echo
echo "== summary: $pass pass, $warn warn, $fail fail =="
[ "$fail" -eq 0 ] || exit 1
