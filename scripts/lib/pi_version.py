"""Pi CLI version checks shared by the Python tooling (and, via the command
line below, by scripts/lib/pi-cli.sh).

Pi floats to the latest release (``./dot update`` runs ``pi update --self``);
the dotfiles only require AT LEAST a minimum version. The installed version is
read from the package's package.json — Pi is never launched to ask, because
its entry point can write (Node's compile cache, a settings lock) even for
``--version``, and read-only paths must write nothing.

Version grammar (identical in pi-cli.sh's ``pi_version_at_least``): three
dot-separated components of 1-6 ASCII digits, nothing else.

Command line: ``python3 -B pi_version.py installed-version <absolute-pi-path>``
prints the version (exit 0), or a reason on stderr with exit 3 (not a
supported global npm install, including a package.json that does not name
the package) or 4 (verified package manifest, version unreadable).
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

PACKAGE = "@earendil-works/pi-coding-agent"
_RELEASE = re.compile(r"([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})")
# <prefix>/lib/node_modules/<package>/dist/[bundle/]cli.js — npm's global layout.
_GLOBAL_CLI = re.compile(r"(/.*)/lib/node_modules/" + re.escape(PACKAGE) + r"/dist/(?:bundle/)?cli\.js")


class NotNpmLayout(ValueError):
    """The pi executable is not a supported global npm install."""


class MetadataUnavailable(ValueError):
    """A global npm install, but its package.json version cannot be read."""


def parse(version: object) -> tuple[int, int, int]:
    """Return an x.y.z release version (1-6 ASCII digits each) as a tuple; ValueError otherwise."""
    match = _RELEASE.fullmatch(version) if isinstance(version, str) else None
    if match is None:
        raise ValueError(f"not a release version: {version!r}")
    major, minor, patch = (int(part) for part in match.groups())
    return major, minor, patch


def at_least(installed: str, minimum: str) -> bool:
    """True when ``installed`` >= ``minimum`` (numeric, so 1.10.0 > 1.9.0)."""
    return parse(installed) >= parse(minimum)


def require(installed: str, minimum: str) -> None:
    """Raise ValueError with an actionable message unless installed >= minimum."""
    try:
        ok = at_least(installed, minimum)
    except ValueError:
        parse(minimum)  # a bad minimum is a bad baseline, not a bad install
        raise ValueError(f"Pi version {installed!r} is not a release version (minimum {minimum}); "
                         "run `pi update --self` (or ./dot update)") from None
    if not ok:
        raise ValueError(f"Pi {installed} is older than the minimum {minimum}; "
                         "run `pi update --self` (or ./dot update)")


def package_root(pi_path: str) -> Path:
    """The package directory behind ``pi_path`` when it is a global npm install.

    ``pi_path`` must be absolute (a relative PATH result could resolve to a
    different file once run from another directory), executable, resolve to
    ``<prefix>/lib/node_modules/<package>/dist/[bundle/]cli.js`` with no other
    node_modules, pnpm, or Vite+ directory in the way, and live in
    ``<prefix>/bin``. Project-local, pnpm, Vite+, and linked installs fail.
    """
    def refuse(detail: str) -> NotNpmLayout:
        return NotNpmLayout(f"{pi_path} is not a global npm install of {PACKAGE} ({detail})")

    if not os.path.isabs(pi_path):
        raise refuse("not an absolute path")
    if not (os.path.isfile(pi_path) and os.access(pi_path, os.X_OK)):
        raise refuse("not an executable file")
    resolved = os.path.realpath(pi_path)
    match = _GLOBAL_CLI.fullmatch(resolved)
    if match is None or "/node_modules/" in match[1] + "/" or any(
            part in resolved for part in ("/.vite-plus/", "/.pnpm/")):
        raise refuse(f"resolves to {resolved}")
    prefix = match[1]
    if os.path.realpath(os.path.dirname(pi_path)) != prefix + "/bin":
        raise refuse(f"not in the install's bin directory {prefix}/bin")
    return Path(prefix) / "lib/node_modules" / PACKAGE


def installed_version(pi_path: str) -> str:
    """The version in package.json of the global npm install behind ``pi_path``.

    The install is only verified once its package.json is readable JSON naming
    PACKAGE: a missing, unreadable, or non-object manifest, or one naming any
    other package, is NotNpmLayout (never run). MetadataUnavailable means a
    verified PACKAGE manifest whose version is not a release version.
    """
    root = package_root(pi_path)
    manifest = root / "package.json"

    def refuse(detail: str) -> NotNpmLayout:
        return NotNpmLayout(f"{pi_path} is not a global npm install of {PACKAGE} ({manifest} {detail})")

    try:
        metadata = json.loads(manifest.read_text())
    except (OSError, UnicodeDecodeError, ValueError) as error:
        raise refuse(f"cannot be read: {error}") from None
    if not isinstance(metadata, dict):
        raise refuse("is not a JSON object")
    if metadata.get("name") != PACKAGE:
        raise refuse(f"names {metadata.get('name')!r}")
    version = metadata.get("version")
    try:
        parse(version)
    except ValueError:
        raise MetadataUnavailable(f"{manifest} version {version!r} is not a release version") from None
    return version


def _main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] != "installed-version":
        print("usage: pi_version.py installed-version <absolute-pi-path>", file=sys.stderr)
        return 2
    try:
        print(installed_version(argv[1]))
    except NotNpmLayout as error:
        print(error, file=sys.stderr)
        return 3
    except MetadataUnavailable as error:
        print(error, file=sys.stderr)
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
