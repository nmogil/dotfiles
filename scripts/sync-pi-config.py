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

# Shared Pi version helper; never write bytecode into the repo (a dry run of
# ./dot update must write nothing).
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import pi_version  # noqa: E402

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
# Files another program owns and rewrites inside a managed tree. The baseline
# never captures, applies, reports, or retires them, even when an older bundle
# or ownership record names them. rexume's daemon rewrites its Pi extension
# whenever it differs from its own version (docs/rexume.md).
DAEMON_OWNED = {".pi/agent/extensions/rexume.ts"}
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
    if path.is_absolute() or ".." in path.parts or str(path) != name or name in DAEMON_OWNED:
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


def extension_dependency_drift(home: Path, files: dict[str, bytes]) -> list[str]:
    """Managed local extensions whose runtime npm dependencies do not resolve.

    The baseline never carries node_modules, so an extension with runtime
    `dependencies` needs `npm install` on each machine (`packages --apply`).
    This is a read-only presence probe (an installed package.json in the
    extension's node_modules or a parent's, up to home), not a module load.
    npm workspace links are symlinks, so the probe follows them without
    writing or reading their contents.
    """
    drift = []
    for name in sorted(files):
        parts = PurePosixPath(name).parts
        if len(parts) != 5 or parts[:3] != (".pi", "agent", "extensions") or parts[4] != "package.json":
            continue
        try:
            manifest = json.loads(files[name])
        except ValueError:
            manifest = None
        if not isinstance(manifest, dict):
            raise ValueError(f"invalid extension manifest: {name}")
        dependencies = manifest.get("dependencies") or {}
        # npm names never start with ".", which also rules out "."/".." traversal.
        if not isinstance(dependencies, dict) or any(
            not re.fullmatch(r"(?:@[\w-][\w.-]*/)?[\w-][\w.-]*", dependency) for dependency in dependencies
        ):
            raise ValueError(f"invalid extension dependencies: {name}")
        directory = PurePosixPath(name).parent
        for dependency in sorted(dependencies):
            candidates = [directory.parents[up - 1] if up else directory for up in range(len(parts))]
            if not any((home / str(base) / "node_modules" / dependency / "package.json").is_file()
                       for base in candidates):
                print(f"extension dependency drift: {directory} missing {dependency}")
                drift.append(str(directory))
                break
    return drift


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


def installed_pi() -> tuple[str, str]:
    """(absolute pi path, version from its package.json). Never launches Pi:
    its entry point can write even for --version, and previews write nothing.
    Raises pi_version.NotNpmLayout / MetadataUnavailable."""
    pi_path = shutil.which("pi")
    if pi_path is None:
        raise pi_version.NotNpmLayout("pi is not installed (./dot pi install)")
    return pi_path, pi_version.installed_version(pi_path)


def load_bundle(bundle: Path) -> tuple[dict, dict[str, bytes]]:
    manifest = object_file(safe_path(bundle, "manifest.json"))
    version = manifest.get("piVersion")
    files = manifest.get("files")
    try:
        pi_version.parse(version)
    except ValueError:
        version = None
    if manifest.get("version") != 1 or version is None:
        raise ValueError("invalid Pi baseline manifest")
    if not isinstance(files, dict) or SETTINGS not in files:
        raise ValueError("baseline is missing its file manifest or settings")
    result = {}
    for name, digest in files.items():
        if name in DAEMON_OWNED:
            continue  # captured before it was excluded; never applied
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
    parser.add_argument("--protect-local", action="store_true",
                        help="apply: refuse (exit 3) to replace or archive any live file that differs from "
                             "the incoming baseline unless it matched --previous-bundle")
    parser.add_argument("--previous-bundle", type=Path,
                        help="with --protect-local: the baseline this machine was last updated from")
    args = parser.parse_args()
    home, bundle = args.home.absolute(), args.bundle.absolute()
    if args.command == "check" and args.apply:
        parser.error("check never writes")
    if args.protect_local and args.command != "apply":
        parser.error("--protect-local only applies to apply")
    if args.previous_bundle is not None and not args.protect_local:
        parser.error("--previous-bundle requires --protect-local")
    if args.command == "capture":
        if args.exclude:
            parser.error("capture always records the full source baseline")
        files = capture(home)
        try:
            version = installed_pi()[1]
        except ValueError as error:
            raise ValueError(f"could not determine the Pi version: {error}") from None
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
    if isinstance(previous, list):
        previous = [name for name in previous if name not in DAEMON_OWNED]  # never retired
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
    # The manifest's piVersion is a MINIMUM: Pi floats to the latest release.
    # Previews (apply/packages without --apply) report an unreadable version;
    # check and every write refuse it.
    minimum = manifest["piVersion"]
    pi_path = "pi"
    try:
        pi_path, version = installed_pi()
    except ValueError as error:
        if args.apply or args.command == "check":
            raise ValueError(f"cannot verify the Pi CLI version (minimum {minimum}): {error}") from None
        print(f"Pi CLI: version gate not previewed — {error} (minimum {minimum})")
    else:
        print(f"Pi CLI: {version} (minimum {minimum})")
        pi_version.require(version, minimum)
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
    dependency_drift = extension_dependency_drift(home, files) if args.command in ("check", "packages") else []
    if args.command == "packages":
        for directory in dependency_drift:
            print(f"{'npm install in' if args.apply else 'would npm install in'} {directory}")
            if args.apply:
                local = safe_path(home, directory + "/package.json")
                # Never run npm (and its lifecycle scripts) against a manifest
                # other than the reviewed baseline one.
                if not local.is_file() or local.read_bytes() != files[directory + "/package.json"]:
                    raise ValueError(f"run apply --apply before installing {directory} dependencies")
                # npm may treat a parent package.json (e.g. an ~/.pi workspace)
                # as the root and update that root's lockfile and node_modules.
                subprocess.run(["npm", "install", "--no-audit", "--no-fund"],
                               cwd=safe_path(home, directory), check=True)
        # Explicit refreshes also resolve the floating package again, even if
        # already installed. Read-only checks never query the npm registry.
        for source in package_sources:
            if source not in package_drift and source not in FLOATING_PACKAGES:
                continue
            print(f"{'install' if args.apply else 'would install'} {source}")
            if args.apply:
                environment = dict(os.environ, PI_CODING_AGENT_DIR=str(home / ".pi/agent"))
                with tempfile.TemporaryDirectory(prefix="pi-packages-") as directory:
                    subprocess.run([pi_path, "install", source, "--no-approve"], cwd=directory,
                                   env=environment, check=True)
        return 0
    # Local changes: a live file this run would replace or archive that does
    # not match the previous baseline (or that baseline did not manage), or a
    # previously managed file that was deleted locally and would be restored.
    # Either may be uncaptured work, so nothing is written. Checked in this
    # process, immediately before any write. Files new to the baseline that are
    # absent here are simply installed.
    protected = []
    if args.protect_local:
        prior = load_bundle(args.previous_bundle.absolute())[1] if args.previous_bundle else {}
        for name in sorted(set(changes) | set(removed)):
            target = safe_path(home, name)
            if not target.exists() and not target.is_symlink():
                if name in prior:
                    protected.append(name)  # deleted locally; apply would restore it
                continue
            if name in prior:
                if name == SETTINGS:
                    actual = object_file(target)
                    if {key: actual[key] for key in actual if key in PREFERENCES} == json.loads(prior[name]):
                        continue
                elif target.is_file() and target.read_bytes() == prior[name]:
                    continue
            protected.append(name)
        for name in protected:
            print(f"local change  {name}")
        if protected and args.apply:
            print(f"pi-config: {len(protected)} live file(s) differ from the previous baseline and would be "
                  "replaced or archived; review them (capture on the source machine) or apply without "
                  "--protect-local", file=sys.stderr)
            return 3
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
    if protected:
        return 3
    return 1 if args.command == "check" and (changes or removed or package_drift or dependency_drift) else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"pi-config: {error}", file=sys.stderr)
        sys.exit(2)
