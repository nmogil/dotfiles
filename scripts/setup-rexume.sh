#!/usr/bin/env bash
# setup-rexume.sh — install/check rexume, the daemon that reopens agent
# conversations in Rex panes after a Rex server restart and returns worker
# results to orchestrators (https://github.com/Entwining/rexume, MIT).
# See docs/rexume.md.
#
#   Binary. macOS (Apple Silicon, macOS 15+): Homebrew owns it (Brewfile:
#          entwining/tap/rexume); --apply only installs it when missing.
#          Linux (x86_64): the release pinned in config/rexume/release.pins;
#          the archive must match its sha256 AND pass `gh attestation verify`
#          against the pinned signer workflow, and the binary inside must match
#          its sha256, before ~/.local/bin/rexume is touched.
#   Hooks and daemon. `rexume install`, run only after a read-only probe shows
#          the Rex server takes a block ID where a session goes (Rex
#          0.1.0-preview.23+), with PI_CODING_AGENT_DIR removed from its
#          environment so it writes the Pi extension to the personal profile
#          (~/.pi/agent) only. It refuses while any work profile
#          (~/.pi/agent-*) has rexume.ts or shares ~/.pi/agent/extensions:
#          rexume reopens Pi without PI_CODING_AGENT_DIR, so a work
#          conversation would come back under the personal profile.
#
# Checks are read-only: they run rexume only as `rexume status`, and only a
# verified binary; ask Homebrew only for `brew --cellar`; and query systemd or
# launchd without changing anything. --dry-run writes nothing and does no
# network. Nothing here stops or restarts the Rex server or types into panes.
#
# Exit codes: 0 ok; 1 problem (differs, failed, refused); 2 usage;
# 3 (--check only) rexume is not installed at all.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="$ROOT/config/rexume/release.pins"
LABEL=io.github.entwining.rexume

usage() {
  cat <<'EOF'
usage: ./dot rexume [--dry-run | --check | --apply [--force]]
  --dry-run       report what --apply would do (default; changes nothing, no network)
  --check         exit 0 if installed as expected, 3 if not installed at all, 1 otherwise
  --apply         install rexume if missing (Mac: Homebrew; Linux: pinned, attested
                  release), probe the Rex server, then run `rexume install` (hooks,
                  personal Pi extension, daemon) without PI_CODING_AGENT_DIR
  --apply --force Linux only: back up a differing ~/.local/bin/rexume, then install the pin
EOF
}

MODE=--dry-run FORCE=0
case "$#:${1:-}:${2:-}" in
  0::) ;;
  1:--dry-run:|1:--check:|1:--apply:) MODE="$1" ;;
  2:--apply:--force) MODE=--apply FORCE=1 ;;
  1:-h:|1:--help:) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

# shellcheck source=scripts/lib/pinned-release.sh
. "$ROOT/scripts/lib/pinned-release.sh"
PR_NAME=rexume PR_PINS="$PINS" PR_DOC=docs/rexume.md
PR_VERIFY_NOTE="sha256- and GitHub-attestation-verified"
RX_TMP=""
cleanup() {
  pr_cleanup
  if [ -n "$RX_TMP" ]; then rm -rf -- "$RX_TMP"; fi
}
trap cleanup EXIT

say() { pr_say "$@"; }
die() { pr_die "$@"; }

OS="$(uname -s)"
PI_DIR="$HOME/.pi/agent"
PI_EXT="$PI_DIR/extensions/rexume.ts"
REXUME_BIN=""   # set only to a verified binary: Homebrew's, or ~/.local/bin/rexume matching the pin

# ---------------------------------------------------------------- platform
mac_setup() {
  FORMULA="$(pr_pin REXUME_BREW_FORMULA)" || exit 1
  case "$FORMULA" in */*/rexume) ;; *) die "unexpected REXUME_BREW_FORMULA in $PINS" ;; esac
  [ "$(uname -m)" = arm64 ] || die "no macOS rexume build for $(uname -m) (upstream ships Apple Silicon only, macOS 15+)"
}

linux_setup() {
  local arch
  arch="$(uname -m)"
  [ "$arch" = x86_64 ] || die "no pinned rexume build for Linux $arch (only x86_64 is pinned; see docs/rexume.md)"
  pr_load_linux_pins REXUME 'rexume-[0-9.]+-x86_64-unknown-linux-musl\.tar\.gz'
  MEMBER="$(pr_pin REXUME_LINUX_X86_64_BINARY_MEMBER)" || exit 1
  [ "$MEMBER" = "${PR_ARCHIVE%.tar.gz}/bin/rexume" ] \
    || die "bad REXUME_LINUX_X86_64_BINARY_MEMBER in $PINS (expected ${PR_ARCHIVE%.tar.gz}/bin/rexume)"
  ATTEST_REPO="$(pr_pin REXUME_ATTESTATION_REPO)" || exit 1
  ATTEST_WORKFLOW="$(pr_pin REXUME_ATTESTATION_SIGNER_WORKFLOW)" || exit 1
  printf '%s\n' "$ATTEST_REPO" | grep -Eqx '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' \
    || die "bad REXUME_ATTESTATION_REPO in $PINS"
  case "$ATTEST_WORKFLOW" in
    "$ATTEST_REPO"/.github/workflows/*) ;;
    *) die "bad REXUME_ATTESTATION_SIGNER_WORKFLOW in $PINS (must be in $ATTEST_REPO)" ;;
  esac
  printf '%s\n' "${ATTEST_WORKFLOW#"$ATTEST_REPO"/.github/workflows/}" | grep -Eqx '[A-Za-z0-9_.-]+\.ya?ml' \
    || die "bad REXUME_ATTESTATION_SIGNER_WORKFLOW in $PINS"
}

# verify_attestation <archive>: GitHub's build provenance for the archive must
# come from the pinned repository's pinned release workflow. Upstream requires
# this before the binary goes on PATH; without gh, nothing is installed.
verify_attestation() {
  local out
  command -v gh >/dev/null 2>&1 \
    || { say "rexume: gh (the GitHub CLI) is required to verify the release's GitHub attestation" >&2; return 1; }
  if ! out="$(gh attestation verify "$1" --repo "$ATTEST_REPO" --signer-workflow "$ATTEST_WORKFLOW" 2>&1)"; then
    say "rexume: gh attestation verify failed for ${1##*/} (signer workflow $ATTEST_WORKFLOW):" >&2
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /' >&2
    return 1
  fi
  say "verified the GitHub attestation of ${1##*/} (signer workflow $ATTEST_WORKFLOW)"
}

# ---------------------------------------------------------------- state (read-only)
job_file() {
  local cfg="${XDG_CONFIG_HOME:-}"
  if [ "$OS" = Darwin ]; then printf '%s' "$HOME/Library/LaunchAgents/$LABEL.plist"; return; fi
  case "$cfg" in /*) ;; *) cfg="$HOME/.config" ;; esac
  printf '%s' "$cfg/systemd/user/rexume.service"
}

daemon_active() {
  local out
  if [ "$OS" = Darwin ]; then
    out="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null)" || return 1
    printf '%s\n' "$out" | grep -Eq '^[[:space:]]*state = running[[:space:]]*$'
  else
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl --user is-active --quiet rexume
  fi
}

# work_profile_issues <strict 0|1>: sets WP_ISSUES to one line per work Pi
# profile (~/.pi/agent-*) that has rexume.ts. With strict, a profile whose
# extensions directory is the personal one also counts: `rexume install` would
# write rexume.ts into it.
work_profile_issues() {
  local strict="$1" d ext real personal="" line
  WP_ISSUES=""
  if [ -d "$PI_DIR/extensions" ]; then personal="$(cd -P "$PI_DIR/extensions" 2>/dev/null && pwd -P || true)"; fi
  for d in "$HOME"/.pi/agent-*; do
    [ -d "$d" ] || continue
    ext="$d/extensions" real="" line=""
    if [ -d "$ext" ]; then real="$(cd -P "$ext" 2>/dev/null && pwd -P || true)"; fi
    if [ -e "$ext/rexume.ts" ] || [ -L "$ext/rexume.ts" ]; then
      line="work Pi profile has $ext/rexume.ts"
      if [ -n "$real" ] && [ "$real" = "$personal" ]; then line="$line (its extensions directory shares $PI_DIR/extensions)"; fi
    elif [ "$strict" = 1 ] && [ -n "$real" ] && [ "$real" = "$personal" ]; then
      line="work Pi profile $d: $ext shares $PI_DIR/extensions, where rexume install writes rexume.ts"
    fi
    if [ -n "$line" ]; then WP_ISSUES="${WP_ISSUES:+$WP_ISSUES
}$line"; fi
  done
}

# binary_status: BIN_RC 0 (verified; REXUME_BIN set), 3 (absent), 1 (problem). Prints why.
binary_status() {
  BIN_RC=0
  if [ "$OS" = Darwin ]; then
    pr_brew_classify "$FORMULA" || BIN_RC=$?
    if [ "$BIN_RC" = 0 ]; then REXUME_BIN="$PR_BREW_BIN"; fi
  else
    pr_linux_check || BIN_RC=$?
    if [ "$BIN_RC" = 0 ]; then REXUME_BIN="$PR_DST"; fi
  fi
}

# ---------------------------------------------------------------- --check
do_check() {
  local any=0 problems="" out hooks job
  binary_status
  [ "$BIN_RC" = 3 ] || any=1
  [ "$BIN_RC" != 1 ] || problems="${problems}
  the rexume binary is not as expected (see above)"
  [ "$BIN_RC" != 3 ] || problems="${problems}
  the rexume binary is not installed"
  if [ -e "$PI_EXT" ]; then any=1
  else problems="${problems}
  $PI_EXT is missing (rexume install writes it when $PI_DIR exists)"
  fi
  job="$(job_file)"
  [ ! -e "$job" ] || any=1
  if daemon_active; then any=1
  elif [ "$OS" = Darwin ]; then problems="${problems}
  the rexume daemon is not active (launchctl print gui/$(id -u)/$LABEL)"
  else problems="${problems}
  the rexume daemon is not active (systemctl --user status rexume)"
  fi
  work_profile_issues 0
  if [ -n "$WP_ISSUES" ]; then
    any=1
    problems="${problems}
$(printf '%s\n' "$WP_ISSUES" | sed 's/^/  /') — remove it; see docs/rexume.md (work profile)"
  fi
  if [ "$any" = 0 ]; then
    say "rexume is not installed (./dot rexume --apply)"
    return 3
  fi
  if [ -z "$problems" ] && [ -n "$REXUME_BIN" ]; then
    # The only rexume run in a check: status reads the state database and settings.
    if out="$(env -u PI_CODING_AGENT_DIR "$REXUME_BIN" status 2>&1)"; then
      hooks="$(printf '%s\n' "$out" | tr -d ' \t\n' | grep -oE '"claude_hooks_missing":(null|\[[^]]*\])' | sed 's/^"claude_hooks_missing"://' || true)"
      case "$hooks" in
        ''|null|'[]') ;;
        *) problems="${problems}
  rexume status: Claude Code hooks missing from settings: $hooks (the daemon adds them when it starts)" ;;
      esac
    else
      problems="${problems}
  rexume status failed: $(printf '%s\n' "$out" | head -n 1)"
    fi
  fi
  if [ -n "$problems" ]; then
    say "rexume is not fully installed:$problems" >&2
    return 1
  fi
  say "rexume is installed: binary, daemon active, personal Pi extension; no work Pi profile has it."
  return 0
}

# ---------------------------------------------------------------- --apply / --dry-run
# The Rex server must take a pane's block ID where a session goes (Rex
# 0.1.0-preview.23+); rexume's hooks and skill rely on it. Read-only listings,
# with --autostart=false so no server is ever started.
rex_probe() {
  local rex sessions sids sid blocks bid="" err
  rex="$(PATH="$INSTALL_PATH"; command -v rex 2>/dev/null || true)"
  if [ -z "$rex" ]; then
    say "rexume: rex (the Rex CLI) is not on PATH; rexume install needs it." >&2
    return 1
  fi
  if ! sessions="$("$rex" --autostart=false ls --json 2>/dev/null </dev/null)"; then
    say "rexume: couldn't list Rex sessions with $rex; is the Rex server running?" >&2
    return 1
  fi
  sids="$(printf '%s\n' "$sessions" | grep -oE '"session_id" *: *"session:[A-Za-z0-9-]+"' | sed -E 's/.*"(session:[A-Za-z0-9-]+)"$/\1/' || true)"
  for sid in $sids; do
    blocks="$("$rex" --autostart=false block ls --json -s "$sid" 2>/dev/null </dev/null)" || continue
    bid="$(printf '%s\n' "$blocks" | grep -oE '"block_id" *: *"block:[A-Za-z0-9-]+"' | sed -E 's/.*"(block:[A-Za-z0-9-]+)"$/\1/' | head -n 1 || true)"
    [ -z "$bid" ] || break
  done
  if [ -z "$bid" ]; then
    say "rexume: the Rex server has no pane to probe with, so I can't verify that it takes a block ID where a session goes (Rex 0.1.0-preview.23+). Open any pane and rerun." >&2
    return 1
  fi
  if ! err="$("$rex" --autostart=false block ls --json -s "$bid" 2>&1 >/dev/null </dev/null)"; then
    say "rexume: the Rex server refuses a block ID where a session goes ($(printf '%s\n' "$err" | head -n 1))." >&2
    say "rexume: it is older than Rex 0.1.0-preview.23, where rexume's hooks would record nothing to reopen. Upgrade the Rex server and its CLI first (Linux: rex-safe-upgrade; Mac: update the Rex app), then rerun." >&2
    return 1
  fi
  say "Rex server takes a block ID where a session goes (Rex 0.1.0-preview.23 or later)."
}

# summarize_install <file>: rexume install's JSON summary as one line of
# field=value, with the non-null notes after it.
summarize_install() {
  local pairs line key val items="" notes=""
  pairs="$(tr '\n\t' '  ' < "$1" | grep -oE '"[a-z_]+" *: *("([^"\\]|\\.)*"|null|true|false|-?[0-9]+)' || true)"
  if [ -z "$pairs" ]; then
    say "rexume install printed:"; sed 's/^/  /' "$1"; return 0
  fi
  while IFS= read -r line; do
    key="$(printf '%s\n' "$line" | sed -E 's/^"([a-z_]+)".*/\1/')"
    val="$(printf '%s\n' "$line" | sed -E 's/^"[a-z_]+" *: *//; s/^"(.*)"$/\1/')"
    case "$key" in
      version|*_label|*_name) continue ;;
      *_note)
        if [ "$val" != null ]; then notes="$notes
  ${key%_note}: $val"; fi
        continue ;;
    esac
    items="${items:+$items, }$key=$val"
  done <<EOF
$pairs
EOF
  say "rexume install: $items"
  if [ -n "$notes" ]; then say "notes:$notes"; fi
}

run_install() {
  RX_TMP="$(mktemp -d)" || die "couldn't make a temporary directory"
  say "running: env -u PI_CODING_AGENT_DIR $REXUME_BIN install (PATH as below, recorded for the daemon)"
  say "  PATH=$INSTALL_PATH"
  if ! env -u PI_CODING_AGENT_DIR PATH="$INSTALL_PATH" "$REXUME_BIN" install > "$RX_TMP/out" 2> "$RX_TMP/err"; then
    sed 's/^/  /' "$RX_TMP/out" "$RX_TMP/err" >&2
    die "rexume install failed; see above and docs/rexume.md"
  fi
  if [ -s "$RX_TMP/err" ]; then sed 's/^/  /' "$RX_TMP/err"; fi
  summarize_install "$RX_TMP/out"
}

do_apply() {
  local rc=0 need_brew=0 found
  # 1. What is installed now (read-only).
  if [ "$OS" = Darwin ]; then
    pr_brew_classify "$FORMULA" || rc=$?
    case "$rc" in
      0) REXUME_BIN="$PR_BREW_BIN" ;;
      3) need_brew=1 ;;
      *) return 1 ;;
    esac
  fi

  # 2. Never give a work Pi profile the extension.
  work_profile_issues 1
  if [ -n "$WP_ISSUES" ]; then
    printf '%s\n' "$WP_ISSUES" | sed 's/^/  /' >&2
    if [ "$MODE" = --dry-run ]; then
      say "--apply would refuse: a work Pi profile would load rexume's extension (see docs/rexume.md, work profile)."
      return 0
    fi
    die "refusing to run rexume install: a work Pi profile would load rexume's extension, and rexume reopens Pi without PI_CODING_AGENT_DIR, so its conversations would come back under the personal profile. See docs/rexume.md (work profile); nothing changed."
  fi

  # 3. The PATH rexume install records for the daemon. Its hooks run `rexume`
  #    by name, so on Linux ~/.local/bin must be on it.
  INSTALL_PATH="$PATH"
  if [ "$OS" = Linux ]; then
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) INSTALL_PATH="$HOME/.local/bin:$PATH" ;; esac
  fi

  if [ "$MODE" = --dry-run ]; then
    if [ "$OS" = Darwin ]; then
      if [ "$need_brew" = 1 ]; then say "would run: brew install $FORMULA"; fi
    else
      pr_linux_apply --dry-run "$FORCE" "$MEMBER"
    fi
    say "would check (read-only) that the Rex server takes a block ID where a session goes (Rex 0.1.0-preview.23+)"
    say "would run: env -u PI_CODING_AGENT_DIR ${REXUME_BIN:-$HOME/.local/bin/rexume} install (hooks, personal Pi extension, daemon; PATH=$INSTALL_PATH)"
    return 0
  fi

  # 4. Preflight before anything is installed.
  if [ "$OS" = Linux ] && [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    die "XDG_RUNTIME_DIR is not set, so rexume install can't find the Rex server or the systemd user manager. Run this from a login session; nothing changed."
  fi
  rex_probe || die "not running rexume install; nothing changed."

  # 5. The binary.
  if [ "$OS" = Darwin ]; then
    if [ "$need_brew" = 1 ]; then
      command -v brew >/dev/null 2>&1 || die "Homebrew is required on macOS (./dot setup mac)"
      brew install "$FORMULA" || die "brew install $FORMULA failed"
      rc=0; pr_brew_classify "$FORMULA" || rc=$?
      [ "$rc" = 0 ] || die "rexume isn't usable from Homebrew after brew install; not running rexume install"
      REXUME_BIN="$PR_BREW_BIN"
    fi
  else
    pr_dst_state
    if [ "$PR_STATE" = missing ] || { [ "$PR_STATE" = differs ] && [ "$FORCE" = 1 ]; }; then
      command -v gh >/dev/null 2>&1 \
        || die "gh (the GitHub CLI) is required to verify the release's GitHub attestation; nothing installed"
    fi
    pr_linux_apply --apply "$FORCE" "$MEMBER" verify_attestation
    REXUME_BIN="$PR_DST"
    found="$(PATH="$INSTALL_PATH"; command -v rexume 2>/dev/null || true)"
    if [ "$(pr_resolve "$found" || true)" != "$(pr_resolve "$PR_DST" || true)" ]; then
      die "$found comes before $PR_DST on PATH; rexume's hooks run rexume by name. Remove it or fix PATH; not running rexume install."
    fi
  fi

  # 6. Hooks, extensions, daemon.
  run_install

  # 7. Re-check the work profiles, then everything.
  work_profile_issues 0
  if [ -n "$WP_ISSUES" ]; then
    printf '%s\n' "$WP_ISSUES" | sed 's/^/  /' >&2
    die "rexume install left rexume.ts in a work Pi profile; delete it now (see docs/rexume.md, work profile)."
  fi
  if [ "$OS" = Linux ] && [ "$INSTALL_PATH" != "$PATH" ]; then
    say "note: $HOME/.local/bin is not on this shell's PATH (.zshrc adds it); it was added for rexume install."
  fi
  rc=0; do_check || rc=$?
  return "$rc"
}

# ---------------------------------------------------------------- main
case "$OS" in
  Darwin) [ "$FORCE" = 0 ] || { usage >&2; exit 2; }; mac_setup ;;
  Linux) linux_setup ;;
  *) die "unsupported OS $OS" ;;
esac
case "$MODE" in
  --check) do_check ;;
  *) do_apply ;;
esac
exit 0
