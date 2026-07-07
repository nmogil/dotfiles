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
         Brewfile .zshrc .gitconfig .p10k.zsh .tmux.conf config/hunk/config.toml config/ghostty/config)
for f in "${required[@]}"; do
  if [ -e "$ROOT/$f" ]; then PASS "config present: $f"; else FAIL "missing required file: $f"; fi
done

# --- scripts executable ---
for s in dot setup.sh setup-linux.sh clone-repos.sh harden-vps.sh setup-obsidian-sync.sh scripts/doctor.sh; do
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
for tool in chezmoi herdr claude codex hunk ob tailscale; do
  if have "$tool"; then PASS "$tool present"; else WARN "$tool missing"; fi
done

echo
echo "-- repo buckets under \${GITHUB_REPOS_DIR:-\$HOME/github_repos} --"
REPOS_DIR="${GITHUB_REPOS_DIR:-$HOME/github_repos}"
if [ -d "$REPOS_DIR" ]; then
  PASS "repos dir exists: $REPOS_DIR"
  for b in personal ventures pennie twilio external; do
    [ -d "$REPOS_DIR/$b" ] && PASS "bucket: $b" || WARN "bucket not present: $b"
  done
else
  WARN "repos dir not present: $REPOS_DIR (run: ./dot repos clone)"
fi

echo
echo "-- secret hygiene --"
# repos.txt holds a personal repo list; it must not be tracked.
if git -C "$ROOT" ls-files --error-unmatch repos.txt >/dev/null 2>&1; then
  FAIL "repos.txt is tracked by git — remove it (it should stay gitignored)"
else
  PASS "repos.txt not tracked"
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
