# Image paste into native Rex sessions

On the Mac, copy a screenshot or an image file, focus a Rex pane (local or on a
remote Rex server), and press **Cmd+Shift+V**. The shortcut pastes an image's
file path without pressing Enter. Normal **Cmd+V** remains text paste. With no
image on the clipboard, the image shortcut does nothing.

For a remote pane, the image travels over Rex's existing connection to that
host, is checked against its SHA-256 after upload, and lands in a private
`$TMPDIR/rex-image-paste-<uid>/` directory (normally
`/tmp/rex-image-paste-0/` for root on the VPS). No Moshi, Bankshot, additional
SSH tunnel, or remote package is installed. The host needs standard `sh`,
`base64`, `stty`, and a SHA-256 utility, which the current VPS already has.

Claude Code recognizes pasted image paths. Other agents can read the pasted
file path even if their composer does not automatically make an attachment.

## Source and installation

The reviewed MIT-licensed plugin is vendored unchanged under
`config/rex/rex-image-paste/`, pinned to upstream revision
`1d883efb5d348477796733555306f2e445a3593e`. Its license, source URL, version,
and checksums are recorded beside it. No code is downloaded at paste time.

```sh
./dot rex config                 # dry-run; no changes
./dot rex config --apply         # copy config and verified plugin to this Mac
./dot rex config --check         # validate installed files and Lua
rex config reload               # reload bindings; do not restart the server
```

If `rex` is not on the shell's PATH, the installer locates the bundled CLI or
accepts `REX_BIN=/absolute/path/to/rex`. For the reload command use that absolute
path too. The installed config is `$REX_CONFIG`, or
`${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua` by default; the module is copied
beside it so `require` resolves correctly. Configure the Mac, **not** the VPS.

Existing identical files are left untouched. Differing files fail before any
copy; review the diff before choosing `--apply --force`, which backs up changed
files under `~/.local/state/dotfiles/rex-backups/`. Unrelated files are preserved,
and symlink destinations are refused. The initial installation had no existing
Rex `init.lua` to merge.

This Rex config is opt-in, not automatically applied by the OS setup scripts.
For updates, review the new upstream revision and refresh its vendored files,
checksums, and provenance together. Do not replace the pinned module with an
automatically updated checkout.

## Private overlay

`./dot rex config` also installs an optional private overlay: every regular
file under `DOTFILES_REX_OVERLAY_DIR` (default: `rex/` beside
`DOTFILES_PI_SCAFFOLD_DIR`) is copied to the same path beside `init.lua`,
except a top-level `README.md` and `*.example.json` templates. `init.lua`
checks whether `dotfiles_private.lua` (or `dotfiles_private/init.lua`) exists
beside it; if so it is required normally, so any error inside the overlay fails
`rex config check`, and if not it is skipped, so this repo works on its own.
The private companion uses it for the "Transfer pi Session to Host…" action,
whose source has no license and so cannot live here.

Overlay files get the same rules as the public ones, plus a few more:

- Differing files need `--force`, which backs them up first. Symlinks and
  unsafe names are refused.
- The full destination map (including the real basename of a custom
  `REX_CONFIG`) must be free of collisions, compared case-insensitively
  because the Mac filesystem is: no duplicate destinations, no path that is a
  file in one place and a directory in another, and nothing that maps onto the
  config file or `rex-image-paste/`.
- Machine-local files are never shipped: an overlay containing
  `transfer-targets.json` (a per-machine allowlist) is refused, and the
  existing one is left alone.
- `--apply` first assembles the merged result (the destination files that will
  remain, plus the public and overlay files) in a temporary directory and runs
  `rex config check` on it. If that fails, nothing in the destination changes.
- Each file is replaced by writing a temporary file in the same directory and
  renaming it over the old one, so readers never see a partial file and hard
  links to the old file are not written through.

The installer trusts its source and destination trees. It refuses symlinks
inside them but does not defend against symlinked ancestors of the
destination (a symlinked `~/.config` is common and fine) or against other
processes changing either tree while it runs. Do not edit the overlay or the
Rex config directory concurrently with `./dot rex config`.

## Program resume

`init.lua` also trusts Pi's resume reports (OSC 7577). Pi 1.7+ tells Rex how to
reopen its session (`pi --session <id>`, with `--agent-dir`, and `--session-dir`
when not the default, for a non-default profile such as `~/.pi/agent-work`). Rex
runs that command in the pane after a server restart only if a rule trusts it, and
Rex preview.25 ships no Pi rule. The rules accept a UUID session and profile
directories under `~/.pi` only, and have no `flags` tables (Pi's docs say those
don't work for Pi yet). Check them with `rex config check` ("resume rules"), and a
pane's report with `rex block call -s <session> -b <block> program_resume_records`.
Rex turns program resume off when the server runs as root (the VPS), so there
`rex-safe-upgrade` still lists resume commands.

## Limits

- Mac clipboard only. This is not an image-paste solution for Rex iOS.
- Images larger than 2000 pixels on their long edge are resized by default
  (GIF/WebP skip resizing); unsupported formats such as TIFF/HEIC become PNG.
- A repeated image reuses the remote cached copy. Remote images older than a
  day are removed on a later paste. Local cached images use macOS temporary
  storage; the plugin does not run the same age-based cleanup locally.
- Transfers have a 25-second deadline. Very large files or a slow connection
  can time out; reducing image dimensions helps.
- The image is made available to the focused agent. It is not automatically
  submitted as a new prompt and no third-party upload service is involved.

## Verification

```sh
python3 scripts/tests/rex-config.test.py   # includes overlay install/refusal cases
python3 scripts/tests/rex-image-paste.e2e.py --host '<saved Rex host label>'
bash -n dot scripts/setup-rex-config.sh
```

The installer tests use temporary homes and Rex's actual Lua config validator
on macOS. The e2e harness uses a synthetic image and a uniquely named private
pasteboard, never your general clipboard. It adapts the pinned upstream test
only to select disposable sessions, the module path, and that private
pasteboard. PNG, TIFF, Finder-style copied files, text-only input, large-image
conversion, repeated-image caching, checksum verification, and bracketed paste
are exercised locally and on the chosen host. Test sessions are closed even on
failure; no existing agent pane, draft, or prompt is used.
