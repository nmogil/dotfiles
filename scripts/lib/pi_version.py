"""Pi CLI version checks shared by the Python tooling.

Pi floats to the latest release (``./dot update`` runs ``pi update --self``);
the dotfiles only require AT LEAST a minimum version. The bash counterpart is
scripts/lib/pi-cli.sh (``pi_version_at_least``).
"""
from __future__ import annotations

import re

_RELEASE = re.compile(r"(\d+)\.(\d+)\.(\d+)")


def parse(version: object) -> tuple[int, int, int]:
    """Return a numeric x.y.z release version as a tuple; ValueError otherwise."""
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
