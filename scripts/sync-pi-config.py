#!/usr/bin/env python3
"""Capture/apply a credential-free personal Pi baseline. Never mirror ~/.pi."""
from __future__ import annotations

import argparse
from functools import cache
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath

SETTINGS = ".pi/agent/settings.json"
OWNERSHIP = ".local/state/dotfiles/pi-config-files.json"
# User-approved floating exception; other packages still require exact versions.
FLOATING_PACKAGES = {"npm:@ogulcancelik/pi-codex-compaction"}
# Deliberately exclude auth, MCP, model endpoints, memory destinations, caches,
# trust, sessions, generated npm state, and every non-personal profile.
FILES = {
    ".pi/agent/cloak.json",
    ".pi/agent/keybindings.json",
    ".pi/agent/pi-codex-compaction.json",
    ".pi/agent/pi-droid-styling.json",
    ".pi/agent/pi-codex-subagents/config.json",
    ".pi/agent/pi-codex-subagents/SYSTEM.md",
}
TREES = (
    ".pi/agent/extensions", ".pi/agent/skills", ".pi/agent/themes",
    ".pi/agent/prompts", ".pi/agent/pi-codex-subagents/agents",
    ".agents/skills/find-skills",
)
# Rex owns its generated skill/hook files; install those with rex skill setup.
PREFERENCES = {
    "theme", "cloak", "defaultProvider", "defaultModel", "defaultThinkingLevel",
    "enabledModels", "packages", "tuiMode", "hideThinkingBlock", "collapseChangelog",
    "quietStartup", "compaction", "branchSummary", "terminal", "images",
    "steeringMode", "followUpMode", "doubleEscapeAction", "treeFilterMode",
    "editorPaddingX", "outputPad", "autocompleteMaxVisible", "showHardwareCursor",
    "fullscreenExitOutput", "fullscreenScrollbar", "fullscreenCopyOnSelect",
    "fullscreenWheelScrollLines", "showCacheMissNotices", "enableSkillCommands",
    "enableInstallTelemetry", "enableAnalytics", "retry", "transport", "markdown",
}
SECRET = re.compile(
    rb"sk-ant-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{20,}|"
    rb"sk-[A-Za-z0-9]{32,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|"
    rb"AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{20,}|"
    rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"
)
SKIP = {"node_modules", ".git", ".cache", "__pycache__", ".DS_Store"}


def object_file(path: Path) -> dict:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path.name}")
    return value


def preferences(value: dict) -> dict:
    result = {key: value[key] for key in sorted(PREFERENCES) if key in value}
    # Only the reviewed compaction package may float. Local/git package sources
    # and other unpinned packages still require separate review.
    packages = result.get("packages", [])
    if not isinstance(packages, list) or any(
        not isinstance(item, str)
        or (item not in FLOATING_PACKAGES
            and not re.fullmatch(r"npm:(?:@[\w.-]+/)?[\w.-]+@\d+\.\d+\.\d+(?:-[\w.-]+)?", item))
        for item in packages
    ):
        raise ValueError("portable packages must be exact-version npm sources or approved floating compaction")
    encoded = json.dumps(result)
    if "https://" in encoded or "http://" in encoded:
        raise ValueError("portable settings contain a URL; review machine-local configuration")
    return result


def encoded(value: dict) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


def allowed(name: str) -> bool:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or str(path) != name:
        return False
    if any(part in SKIP or part.startswith(".env") or ".bak" in part for part in path.parts):
        return False
    return name == SETTINGS or name in FILES or any(name.startswith(root + "/") for root in TREES)


def safe_path(root: Path, name: str) -> Path:
    path = root
    if root.is_symlink():
        raise ValueError("refusing symlink root")
    for part in PurePosixPath(name).parts:
        path = path / part
        if path.is_symlink():
            raise ValueError(f"refusing symlink: {name}")
    return path


@cache
def private_patterns() -> list[re.Pattern]:
    default = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "dotfiles/pi-scaffold-blocklist.txt"
    blocklist = Path(os.environ.get("DOTFILES_PI_BLOCKLIST", default))
    patterns = []
    if blocklist.exists():
        for number, line in enumerate(blocklist.read_text().splitlines(), 1):
            if line.strip() and not line.lstrip().startswith("#"):
                try:
                    patterns.append(re.compile(line.encode()))
                except re.error:
                    raise ValueError(f"invalid private blocklist pattern at line {number}") from None
    return patterns


def checked(data: bytes, name: str) -> bytes:
    if SECRET.search(data) or any(pattern.search(data) for pattern in private_patterns()):
        raise ValueError(f"possible credential in {name}; nothing copied")
    return data


def capture(home: Path) -> dict[str, bytes]:
    paths = set(FILES)
    for tree in TREES:
        root = safe_path(home, tree)
        if root.exists():
            for directory, dirs, files in os.walk(root, followlinks=False):
                for entry in dirs + files:
                    path = Path(directory) / entry
                    if path.is_symlink():
                        raise ValueError(f"refusing symlink in {tree}")
                dirs[:] = [d for d in dirs if d not in SKIP and not d.startswith(".env") and ".bak" not in d]
                paths.update(str((Path(directory) / name).relative_to(home)) for name in files)
    result = {}
    for name in sorted(paths):
        if allowed(name):
            path = safe_path(home, name)
            if path.is_file():
                result[name] = checked(path.read_bytes(), name)
    result[SETTINGS] = checked(encoded(preferences(object_file(safe_path(home, SETTINGS)))), SETTINGS)
    return result


def load_bundle(bundle: Path) -> tuple[dict, dict[str, bytes]]:
    manifest = object_file(safe_path(bundle, "manifest.json"))
    version = manifest.get("piVersion")
    files = manifest.get("files")
    if manifest.get("version") != 1 or not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("invalid Pi baseline manifest")
    if not isinstance(files, dict) or SETTINGS not in files:
        raise ValueError("baseline is missing its file manifest or settings")
    result = {}
    for name, digest in files.items():
        if not allowed(name):
            raise ValueError(f"non-portable baseline path: {name}")
        data = checked(safe_path(bundle, "files/" + name).read_bytes(), name)
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"baseline checksum mismatch: {name}")
        result[name] = data
    settings = json.loads(result[SETTINGS])
    if not isinstance(settings, dict) or preferences(settings) != settings:
        raise ValueError("baseline settings contain non-portable fields")
    return manifest, result


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def prune_empty_parents(home: Path, name: str) -> None:
    for tree in TREES:
        if name.startswith(tree + "/"):
            boundary = home / (".agents/skills" if tree == ".agents/skills/find-skills" else tree)
            parent = (home / name).parent
            while parent != boundary:
                try:
                    parent.rmdir()  # Never remove directories containing unmanaged files.
                except OSError:
                    return
                parent = parent.parent
            return


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("capture", "apply", "packages", "check"))
    parser.add_argument("--bundle", required=True, type=Path, help="private, credential-free baseline directory")
    parser.add_argument("--home", type=Path, default=Path.home(), help="personal profile's home")
    parser.add_argument("--apply", action="store_true", help="explicitly allow writes; otherwise read-only")
    parser.add_argument("--exclude", action="append", help="machine-local resource prefix to preserve; saved on apply")
    args = parser.parse_args()
    home, bundle = args.home.absolute(), args.bundle.absolute()
    if args.command == "check" and args.apply:
        parser.error("check never writes")
    if args.command == "capture":
        if args.exclude:
            parser.error("capture always records the full source baseline")
        files = capture(home)
        version = subprocess.check_output(["pi", "--version"], text=True).strip()
        if not re.fullmatch(r"\d+\.\d+\.\d+", version):
            raise ValueError("could not determine Pi version")
        manifest = {"version": 1, "piVersion": version, "files": {
            name: hashlib.sha256(data).hexdigest() for name, data in sorted(files.items())
        }}
        # Reject symlink destinations before writing anything.
        for name in files:
            safe_path(bundle, "files/" + name)
        safe_path(bundle, "manifest.json")
        if args.apply:
            # The private bundle is a snapshot. Stale files are not in the new
            # manifest and therefore can never be applied by this tool.
            for name, data in files.items():
                write_atomic(bundle / "files" / name, data)
            write_atomic(bundle / "manifest.json", encoded(manifest))
        print(f"{'Captured' if args.apply else 'Would capture'} {len(files)} files; Pi {version}")
        return 0

    manifest, files = load_bundle(bundle)
    package_sources = json.loads(files[SETTINGS]).get("packages", [])
    ownership = safe_path(home, OWNERSHIP)
    record = object_file(ownership) if ownership.exists() else {}
    previous = record.get("files", [])
    if not isinstance(previous, list) or any(not isinstance(name, str) or not allowed(name) for name in previous):
        raise ValueError("invalid managed-file ownership record")
    exclusions = args.exclude if args.exclude is not None else record.get("excludes", [])
    if not isinstance(exclusions, list) or any(
        not isinstance(name, str) or not (allowed(name) or allowed(name + "/resource"))
        for name in exclusions
    ):
        raise ValueError("invalid machine-local exclusion")
    def excluded(name: str) -> bool:
        return any(name == prefix or name.startswith(prefix + "/") for prefix in exclusions)
    if exclusions:
        print("Machine-local exclusions: " + ", ".join(exclusions))
    files = {name: data for name, data in files.items() if not excluded(name)}
    removed = sorted(name for name in previous if name not in files and not excluded(name) and safe_path(home, name).exists())
    for name in removed:
        if not safe_path(home, name).is_file():
            raise ValueError(f"retired managed file is no longer a regular file: {name}")
    changes = {}
    for name, data in files.items():
        target = safe_path(home, name)
        if name == SETTINGS:
            actual = object_file(target) if target.exists() else {}
            desired = json.loads(data)
            # Keep only genuinely machine-local/unmanaged keys, not remote-only
            # portable preferences. An absent source setting means Pi's default.
            combined = {key: value for key, value in actual.items() if key not in PREFERENCES}
            combined.update(desired)
            if {key: actual[key] for key in actual if key in PREFERENCES} == desired:
                continue
            data = encoded(combined)
        elif target.exists() and target.read_bytes() == data:
            continue
        changes[name] = data
    version = subprocess.check_output(["pi", "--version"], text=True).strip()
    version_ok = version == manifest["piVersion"]
    print(f"Pi CLI: {version} (baseline {manifest['piVersion']})")
    if not version_ok:
        raise ValueError("Pi version differs; install the baseline version first")
    package_drift = []
    for source in package_sources:
        if source in FLOATING_PACKAGES:
            name, expected = source.removeprefix("npm:"), None
        else:
            name, expected = source.removeprefix("npm:").rsplit("@", 1)
        path = safe_path(home, f".pi/agent/npm/node_modules/{name}/package.json")
        actual = object_file(path).get("version") if path.is_file() else "missing"
        installed = isinstance(actual, str) and re.fullmatch(r"\d+\.\d+\.\d+(?:-[\w.-]+)?", actual)
        if not installed or (expected is not None and actual != expected):
            package_drift.append(source)
            print(f"package drift: {name} installed={actual} expected={expected}")
    if args.command == "packages":
        # Explicit refreshes also resolve the floating package again, even if
        # already installed. Read-only checks never query the npm registry.
        for source in package_sources:
            if source not in package_drift and source not in FLOATING_PACKAGES:
                continue
            print(f"{'install' if args.apply else 'would install'} {source}")
            if args.apply:
                environment = dict(os.environ, PI_CODING_AGENT_DIR=str(home / ".pi/agent"))
                with tempfile.TemporaryDirectory(prefix="pi-packages-") as directory:
                    subprocess.run(["pi", "install", source, "--no-approve"], cwd=directory,
                                   env=environment, check=True)
        return 0
    backup = None
    if args.command == "apply" and args.apply and (changes or removed):
        backup_root = safe_path(home, ".local/state/dotfiles/pi-config-backups")
        backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        backup = Path(tempfile.mkdtemp(prefix="apply-", dir=backup_root))
    for name, data in sorted(changes.items()):
        print(f"{'update' if backup else 'drift '} {name}")
        if backup:
            target = home / name
            if target.exists():
                copy = backup / name
                copy.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(target, copy)
            write_atomic(target, data)
    for name in removed:
        print(f"{'archive' if backup else 'stale  '} {name}")
        if backup:
            target = home / name
            archived = backup / name
            archived.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(target), str(archived))
            prune_empty_parents(home, name)
    if args.command == "apply" and args.apply:
        write_atomic(ownership, encoded({"files": sorted(files), "excludes": exclusions}))
    if backup:
        print(f"Backups: {backup}")
    print(f"{len(files)} managed files; {len(changes)} {'updated' if backup else 'differ'}; {len(removed)} retired. Unmanaged files preserved.")
    return 1 if args.command == "check" and (changes or removed or package_drift) else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"pi-config: {error}", file=sys.stderr)
        sys.exit(2)
