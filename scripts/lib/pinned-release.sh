# shellcheck shell=bash
# Results are returned in PR_* globals that the sourcing installer reads.
# shellcheck disable=SC2034
# pinned-release.sh — shared by the installers for single-binary tools that
# ./dot installs from a pinned release (scripts/setup-rexboard.sh,
# scripts/setup-rexume.sh). Sourcing it only defines functions.
#
# Linux: the release named in a data-only pins file, with the archive and the
# binary inside it sha256-verified, installed to ~/.local/bin/<name>:
#   - the pins file is parsed as KEY=value data and never sourced;
#   - nothing downloaded is ever executed, and an existing binary is only
#     hashed, never run;
#   - everything is downloaded and verified before the destination is touched,
#     and the destination is re-checked afterwards;
#   - a missing binary is published with link(2), which never overwrites
#     anything that appeared meanwhile; a forced replacement first backs up and
#     verifies the old binary, then renames exactly that path;
#   - symlinks and directories at the destination are refused;
#   - temporary files are removed on every exit (the caller runs
#     `trap pr_cleanup EXIT`).
# macOS: pr_brew_classify reads what Homebrew installed with `brew --cellar`
# only (never `brew list`, which can start Homebrew's Ruby).
#
# The caller sets PR_NAME (binary and message name), PR_PINS (pins file) and
# PR_DOC (docs path for messages) before calling anything here. pr_die exits 1.

PR_WORK="" PR_STAGE=""

pr_say() { printf '%s\n' "$*"; }
pr_die() { printf '%s: %s\n' "$PR_NAME" "$*" >&2; exit 1; }

pr_cleanup() {
  if [ -n "$PR_STAGE" ]; then rm -f -- "$PR_STAGE"; fi
  if [ -n "$PR_WORK" ]; then rm -rf -- "$PR_WORK"; fi
}

# pr_pin <KEY>: the value of KEY=value in the pins file. Read as data, never sourced.
pr_pin() {
  local value
  [ -f "$PR_PINS" ] || pr_die "missing $PR_PINS"
  value="$(sed -n "s/^$1=//p" "$PR_PINS" | tail -n 1)"
  [ -n "$value" ] || pr_die "$1 is missing from $PR_PINS"
  printf '%s' "$value"
}

pr_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi | cut -d' ' -f1
}

# pr_resolve <path>: the physical path, following symlinks (no readlink -f on macOS).
pr_resolve() {
  local p="$1" link dir
  while [ -L "$p" ]; do
    link="$(readlink "$p")"
    case "$link" in /*) p="$link" ;; *) p="$(dirname "$p")/$link" ;; esac
  done
  dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s' "$dir" "$(basename "$p")"
}

# ------------------------------------------------------------------- macOS
# pr_brew_classify <formula>: what is installed as PR_NAME. Prints why, and
# returns 0 when a Homebrew keg is installed and is what PATH runs (PR_BREW_BIN
# is then that PATH entry and PR_BREW_KEGS its versions), 3 when nothing is
# installed anywhere, 1 for anything else. Never runs the binary.
pr_brew_classify() {
  local formula="$1" cellar="" keg real_kegs resolved
  PR_BREW_BIN="" PR_BREW_KEGS=""
  if command -v brew >/dev/null 2>&1; then
    cellar="$(brew --cellar)" || { pr_say "$PR_NAME: brew --cellar failed; can't tell what Homebrew installed" >&2; return 1; }
    for keg in "$cellar/$PR_NAME"/*/bin/"$PR_NAME"; do
      [ -f "$keg" ] || continue
      keg="${keg%/bin/"$PR_NAME"}"
      PR_BREW_KEGS="${PR_BREW_KEGS:+$PR_BREW_KEGS, }${keg##*/}"
    done
  fi
  PR_BREW_BIN="$(command -v "$PR_NAME" 2>/dev/null || true)"

  if [ -n "$PR_BREW_KEGS" ]; then
    real_kegs="$(cd -P "$cellar/$PR_NAME" && pwd -P)"
    if [ -z "$PR_BREW_BIN" ]; then
      pr_say "$PR_NAME $PR_BREW_KEGS is installed with Homebrew but isn't on PATH (brew link $PR_NAME)" >&2
      return 1
    fi
    if [ ! -f "$PR_BREW_BIN" ] || [ ! -x "$PR_BREW_BIN" ]; then
      pr_say "$PR_NAME at $PR_BREW_BIN is not an executable file; reinstall it with Homebrew" >&2
      return 1
    fi
    resolved="$(pr_resolve "$PR_BREW_BIN" || true)"
    case "$resolved" in
      "$real_kegs"/*) ;;
      *) pr_say "$PR_NAME at $PR_BREW_BIN shadows the Homebrew one ($PR_BREW_KEGS); remove it or fix PATH" >&2; return 1 ;;
    esac
    pr_say "$PR_NAME $PR_BREW_KEGS installed with Homebrew ($formula); Homebrew manages its version."
    return 0
  fi
  if [ -n "$PR_BREW_BIN" ]; then
    pr_say "$PR_NAME at $PR_BREW_BIN is not from Homebrew; remove it or keep managing it by hand." >&2
    return 1
  fi
  return 3
}

# ------------------------------------------------------------------- Linux
# pr_load_linux_pins <PREFIX> <archive-name-regex>: read and validate
# <PREFIX>_VERSION, _RELEASE_URL, _LINUX_X86_64_ARCHIVE, _ARCHIVE_SHA256 and
# _BINARY_SHA256 into PR_VERSION, PR_URL, PR_ARCHIVE, PR_ARCHIVE_SHA and
# PR_BINARY_SHA. Dies on anything malformed. Also sets PR_DIR and PR_DST.
pr_load_linux_pins() {
  local p="$1" archive_re="$2"
  PR_VERSION="$(pr_pin "${p}_VERSION")" || exit 1
  PR_URL="$(pr_pin "${p}_RELEASE_URL")" || exit 1
  PR_ARCHIVE="$(pr_pin "${p}_LINUX_X86_64_ARCHIVE")" || exit 1
  PR_ARCHIVE_SHA="$(pr_pin "${p}_LINUX_X86_64_ARCHIVE_SHA256")" || exit 1
  PR_BINARY_SHA="$(pr_pin "${p}_LINUX_X86_64_BINARY_SHA256")" || exit 1
  printf '%s\n' "$PR_VERSION" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || pr_die "bad ${p}_VERSION in $PR_PINS"
  printf '%s\n' "$PR_ARCHIVE_SHA" | grep -Eqx '[0-9a-f]{64}' || pr_die "bad ${p}_LINUX_X86_64_ARCHIVE_SHA256 in $PR_PINS"
  printf '%s\n' "$PR_BINARY_SHA" | grep -Eqx '[0-9a-f]{64}' || pr_die "bad ${p}_LINUX_X86_64_BINARY_SHA256 in $PR_PINS"
  printf '%s\n' "$PR_ARCHIVE" | grep -Eqx "$archive_re" || pr_die "bad archive name in $PR_PINS"
  printf '%s\n' "$PR_URL" | grep -Eqx '(https://[A-Za-z0-9./_-]+|file:///[A-Za-z0-9./_-]+)' || pr_die "bad ${p}_RELEASE_URL in $PR_PINS"
  PR_DIR="$HOME/.local/bin"
  PR_DST="$PR_DIR/$PR_NAME"
}

# pr_dst_state: sets PR_STATE to missing|match|noexec|differs and PR_DST_SHA;
# dies on a symlink or a non-regular file. Never runs the file.
pr_dst_state() {
  PR_DST_SHA=""
  if [ -L "$PR_DST" ]; then
    pr_die "$PR_DST is a symlink; not touching it. Remove it and rerun."
  elif [ ! -e "$PR_DST" ]; then
    PR_STATE=missing; return 0
  elif [ ! -f "$PR_DST" ]; then
    pr_die "$PR_DST is not a regular file; not touching it."
  fi
  PR_DST_SHA="$(pr_sha256 "$PR_DST")"
  if [ "$PR_DST_SHA" != "$PR_BINARY_SHA" ]; then PR_STATE=differs
  elif [ -x "$PR_DST" ]; then PR_STATE=match
  else PR_STATE=noexec
  fi
}

# pr_linux_check: 0 when ~/.local/bin/<name> matches the pin and nothing else
# shadows it on PATH, 3 when it is missing, 1 otherwise. Prints why.
pr_linux_check() {
  local onpath
  pr_dst_state
  case "$PR_STATE" in
    missing) pr_say "$PR_NAME is not installed at $PR_DST (./dot $PR_NAME --apply)"; return 3 ;;
    differs) pr_say "$PR_NAME at $PR_DST differs from the pinned $PR_VERSION build; see $PR_DOC" >&2; return 1 ;;
    noexec) pr_say "$PR_NAME at $PR_DST matches the pin but is not executable (./dot $PR_NAME --apply)" >&2; return 1 ;;
  esac
  onpath="$(command -v "$PR_NAME" 2>/dev/null || true)"
  if [ -n "$onpath" ] && [ "$(pr_resolve "$onpath" || true)" != "$(pr_resolve "$PR_DST" || true)" ]; then
    pr_say "$PR_NAME at $onpath shadows $PR_DST on PATH; remove it or fix PATH" >&2
    return 1
  fi
  pr_say "$PR_NAME at $PR_DST matches the pinned $PR_VERSION build."
  return 0
}

# pr_linux_apply <--dry-run|--apply> <force 0|1> <member> [verify-fn]: make
# ~/.local/bin/<name> the pinned binary <member> of the pinned archive. With
# verify-fn, `verify-fn <archive-path>` must also succeed on the downloaded,
# checksum-verified archive before anything is extracted. Sets PR_RESULT to
# match|planned|restored|installed; dies (exit 1) on any failure, with nothing
# installed.
pr_linux_apply() {
  local mode="$1" force="$2" member="$3" verify="${4:-}" got decided before backup
  local note="${PR_VERIFY_NOTE:-sha256-verified}"
  pr_dst_state
  case "$mode:$PR_STATE" in
    *:match) PR_RESULT=match; pr_say "$PR_NAME $PR_VERSION already installed at $PR_DST (matches the pin); nothing to do."; return 0 ;;
    --dry-run:missing) PR_RESULT=planned; pr_say "would install $PR_NAME $PR_VERSION to $PR_DST from $PR_URL/$PR_ARCHIVE ($note)"; return 0 ;;
    --dry-run:noexec) PR_RESULT=planned; pr_say "would restore the execute bit on $PR_DST (it matches the pin)"; return 0 ;;
    --dry-run:differs)
      PR_RESULT=planned
      pr_say "$PR_DST differs from the pinned $PR_VERSION build; --apply leaves it alone (--apply --force backs it up and installs the pin)"
      return 0 ;;
    --apply:noexec)
      chmod u+x "$PR_DST" || pr_die "couldn't make $PR_DST executable"
      PR_RESULT=restored
      pr_say "restored the execute bit on $PR_DST (matches the pinned $PR_VERSION build)."
      return 0 ;;
    --apply:differs)
      [ "$force" = 1 ] || pr_die "$PR_DST differs from the pinned $PR_VERSION build; review it, then rerun with --apply --force (backs it up)" ;;
  esac
  decided="$PR_STATE" before="$PR_DST_SHA"

  # Download and verify everything before touching the destination.
  PR_WORK="$(mktemp -d)" || pr_die "couldn't make a temporary directory"
  curl -fsSL --proto '=https,file' --retry 2 -o "$PR_WORK/$PR_ARCHIVE" "$PR_URL/$PR_ARCHIVE" || pr_die "could not download $PR_URL/$PR_ARCHIVE"
  got="$(pr_sha256 "$PR_WORK/$PR_ARCHIVE")"
  [ "$got" = "$PR_ARCHIVE_SHA" ] || pr_die "checksum mismatch for $PR_ARCHIVE (got $got); nothing installed"
  if [ -n "$verify" ]; then
    "$verify" "$PR_WORK/$PR_ARCHIVE" || pr_die "$PR_ARCHIVE failed verification; nothing installed"
  fi
  mkdir "$PR_WORK/x" || pr_die "couldn't make a temporary directory"
  tar -xzf "$PR_WORK/$PR_ARCHIVE" -C "$PR_WORK/x" "$member" || pr_die "$PR_ARCHIVE has no $member"
  [ -f "$PR_WORK/x/$member" ] && [ ! -L "$PR_WORK/x/$member" ] || pr_die "$member in $PR_ARCHIVE is not a regular file"
  got="$(pr_sha256 "$PR_WORK/x/$member")"
  [ "$got" = "$PR_BINARY_SHA" ] || pr_die "binary checksum mismatch for $member (got $got); nothing installed"

  # The destination must still be what we decided on before the download.
  pr_dst_state
  if [ "$PR_STATE" != "$decided" ] || [ "$PR_DST_SHA" != "$before" ]; then
    pr_die "$PR_DST changed while the release downloaded; nothing installed. Rerun to review it."
  fi
  mkdir -p "$PR_DIR" || pr_die "couldn't create $PR_DIR"
  if [ "$decided" = differs ]; then
    backup="$HOME/.local/state/dotfiles/$PR_NAME-backups/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$backup" || pr_die "couldn't create $backup; nothing installed"
    cp -p "$PR_DST" "$backup/$PR_NAME" || pr_die "couldn't back up $PR_DST; nothing installed"
    [ "$(pr_sha256 "$backup/$PR_NAME")" = "$before" ] || pr_die "the backup of $PR_DST doesn't match it; nothing installed"
    pr_say "backed up the previous $PR_DST to $backup/$PR_NAME"
  fi
  PR_STAGE="$(mktemp "$PR_DIR/.$PR_NAME.XXXXXX")" || { PR_STAGE=""; pr_die "couldn't write to $PR_DIR; nothing installed"; }
  cp "$PR_WORK/x/$member" "$PR_STAGE" || pr_die "couldn't stage the new binary; nothing installed"
  chmod 755 "$PR_STAGE" || pr_die "couldn't make the staged binary executable; nothing installed"
  [ "$(pr_sha256 "$PR_STAGE")" = "$PR_BINARY_SHA" ] || pr_die "the staged binary doesn't match the pin; nothing installed"

  if [ "$decided" = missing ]; then
    # link(2) fails if anything exists at PR_DST, so nothing is ever overwritten.
    link "$PR_STAGE" "$PR_DST" 2>/dev/null || pr_die "$PR_DST appeared while installing; it was not overwritten"
    rm -f -- "$PR_STAGE"
  else
    pr_dst_state
    [ "$PR_STATE" = differs ] && [ "$PR_DST_SHA" = "$before" ] || pr_die "$PR_DST changed while installing; nothing replaced"
    # rename(2) replaces exactly PR_DST: it never writes into a directory or through a link.
    perl -e 'rename($ARGV[0], $ARGV[1]) or die "$!\n"' "$PR_STAGE" "$PR_DST" || pr_die "couldn't replace $PR_DST"
  fi
  PR_STAGE=""
  PR_RESULT=installed
  pr_say "installed $PR_NAME $PR_VERSION at $PR_DST"
}
