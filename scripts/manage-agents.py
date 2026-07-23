#!/usr/bin/env python3
"""Read-only inventory and policy checks for local AI-agent capabilities."""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tomllib
from pathlib import Path

# Capability names become path components in later cleanup phases. Keep this
# deliberately narrower than arbitrary config keys: no separators or traversal.
SAFE_NAME = re.compile(r"^(?!\.{1,2}$)[A-Za-z0-9@._:+-]+$")


def names_in(directory: Path, *, file_suffix: str | None = None) -> list[str]:
    if not directory.is_dir():
        return []
    names: set[str] = set()
    for entry in directory.iterdir():
        if entry.is_dir():
            names.add(entry.name)
        elif file_suffix is not None and entry.is_file() and entry.suffix == file_suffix:
            names.add(entry.stem)
    return sorted(names)


def json_object(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def safe_names(values: object) -> list[str]:
    if isinstance(values, dict):
        candidates = values.keys()
    elif isinstance(values, (list, set, tuple)):
        candidates = values
    else:
        return []
    return sorted({value for value in candidates if isinstance(value, str) and SAFE_NAME.fullmatch(value)})


def toml_object(path: Path) -> dict[str, object]:
    try:
        value = tomllib.loads(path.read_text())
    except (OSError, tomllib.TOMLDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def hermes_capabilities(path: Path) -> tuple[list[str], list[str]]:
    """Read only names from the two simple top-level YAML sections we own."""
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return [], []

    mcp_names: list[str] = []
    plugin_names: list[str] = []
    section = ""
    plugin_key = ""
    for line in lines:
        if line and not line.startswith((" ", "\t", "#")):
            section = line[:-1] if line.endswith(":") else ""
            plugin_key = ""
            continue
        if section == "mcp_servers":
            match = re.match(r"^  ([A-Za-z0-9][A-Za-z0-9._-]*):(?:\s|$)", line)
            if match:
                mcp_names.append(match.group(1))
        elif section == "plugins":
            match = re.match(r"^  ([A-Za-z_]+):", line)
            if match:
                plugin_key = match.group(1)
                continue
            if plugin_key == "enabled":
                match = re.match(r"^    -\s+([A-Za-z0-9][A-Za-z0-9._-]*)\s*$", line)
                if match:
                    plugin_names.append(match.group(1))
    return safe_names(mcp_names), safe_names(plugin_names)


def print_names(label: str, names: list[str]) -> None:
    filtered = safe_names(names)
    print(f"{label}: {','.join(filtered) if filtered else '(none)'}")


def agent_paths(home: Path) -> dict[str, Path]:
    pi_root = Path(os.environ.get("PI_HOME", home / ".pi"))
    return {
        # Inventory labels are profile identities, not the caller's active Pi
        # process. Keep personal stable even when PI_CODING_AGENT_DIR is work.
        "pi": pi_root / "agent",
        "claude": Path(os.environ.get("CLAUDE_CONFIG_DIR", home / ".claude")),
        "codex": Path(os.environ.get("CODEX_HOME", home / ".codex")),
        "hermes": Path(os.environ.get("HERMES_HOME", home / ".hermes")),
    }


def directory_digest(directory: Path) -> str:
    digest = hashlib.sha256()
    try:
        root = directory.resolve(strict=True)
        files = sorted(path for path in root.rglob("*") if path.is_file())
        for path in files:
            digest.update(path.relative_to(root).as_posix().encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
    except OSError:
        return ""
    return digest.hexdigest()


def load_policy(policy_dir: Path, name: str) -> dict[str, object]:
    path = policy_dir / name
    policy = json_object(path)
    if not policy:
        raise ValueError(f"missing or invalid policy: {name}")
    return policy


def validate_capability_policy(
    policy: dict[str, object], *, categories: tuple[str, ...], require_all_agents: bool
) -> list[str]:
    errors: list[str] = []
    if policy.get("version") != 1:
        errors.append("version must be 1")
    if not isinstance(policy.get("enforceAssignments"), bool):
        errors.append("enforceAssignments must be boolean")
    agents = policy.get("agents")
    if not isinstance(agents, dict):
        return errors + ["agents must be an object"]

    expected_agents = {"pi", "claude", "codex", "hermes"}
    actual_agents = set(agents)
    if not actual_agents.issubset(expected_agents):
        errors.append("agents contains an unsupported agent")
    if require_all_agents and actual_agents != expected_agents:
        errors.append("agents must define pi, claude, codex, and hermes")

    for agent, config in agents.items():
        if not isinstance(config, dict):
            errors.append(f"{agent} policy must be an object")
            continue
        classified: set[str] = set()
        for category in categories:
            values = config.get(category, [])
            if not isinstance(values, list) or any(
                not isinstance(value, str) or not SAFE_NAME.fullmatch(value) for value in values
            ):
                errors.append(f"{agent}.{category} must contain safe capability names")
                continue
            if len(values) != len(set(values)):
                errors.append(f"{agent}.{category} contains duplicates")
            overlap = classified.intersection(values)
            if overlap:
                errors.append(f"{agent} classifies a capability more than once")
            classified.update(values)
    return errors


def check(policy_dir: Path) -> int:
    try:
        skills = load_policy(policy_dir, "skills.json")
        plugins = load_policy(policy_dir, "plugins.json")
        mcp = load_policy(policy_dir, "mcp-policy.example.json")
    except ValueError as error:
        print(f"FAIL {error}")
        return 1

    print("== agent capability policy check ==")
    errors = validate_capability_policy(
        skills, categories=("shared", "local", "review"), require_all_agents=True
    )
    if errors:
        for error in errors:
            print(f"FAIL skills policy: {error}")
    else:
        print("ok   skills policy")

    plugin_errors = validate_capability_policy(
        plugins, categories=("keep", "review"), require_all_agents=True
    )
    if plugin_errors:
        for error in plugin_errors:
            print(f"FAIL plugins policy: {error}")
    else:
        print("ok   plugins policy")

    if mcp.get("version") != 1 or mcp.get("shareCredentials") is not False:
        errors.append("MCP policy must be version 1 and prohibit credential sharing")
        print("FAIL MCP policy must prohibit credential sharing")
    else:
        print("ok   MCP credentials are declared non-shareable")

    enforcement = skills.get("enforceAssignments") is True and plugins.get("enforceAssignments") is True
    if enforcement:
        errors.append("assignment enforcement is not available in the read-only phase")
        print("FAIL assignment enforcement is not available in the read-only phase")
    else:
        print("WARN assignment enforcement disabled; drift is report-only")
    return 1 if errors or plugin_errors else 0


def installed_plugins(home: Path, paths: dict[str, Path]) -> dict[str, set[str]]:
    pi = set(names_in(paths["pi"] / "extensions", file_suffix=".ts"))

    claude_settings = json_object(paths["claude"] / "settings.json")
    enabled = claude_settings.get("enabledPlugins", {})
    claude = set(
        safe_names(
            [name for name, state in enabled.items() if state is True]
            if isinstance(enabled, dict)
            else []
        )
    )

    codex_config = toml_object(paths["codex"] / "config.toml")
    codex_table = codex_config.get("plugins", {})
    codex = set(
        safe_names(
            [name for name, state in codex_table.items() if state is True]
            if isinstance(codex_table, dict)
            else []
        )
    )

    _, hermes_names = hermes_capabilities(paths["hermes"] / "config.yaml")
    return {"pi": pi, "claude": claude, "codex": codex, "hermes": set(hermes_names)}


def plan(home: Path, policy_dir: Path) -> int:
    try:
        skills_policy = load_policy(policy_dir, "skills.json")
        plugins_policy = load_policy(policy_dir, "plugins.json")
    except ValueError as error:
        print(f"manage-agents: {error}", file=sys.stderr)
        return 2

    if validate_capability_policy(
        skills_policy, categories=("shared", "local", "review"), require_all_agents=True
    ):
        print("manage-agents: invalid skills policy", file=sys.stderr)
        return 2
    if validate_capability_policy(
        plugins_policy, categories=("keep", "review"), require_all_agents=True
    ):
        print("manage-agents: invalid plugins policy", file=sys.stderr)
        return 2

    print("== agent capability cleanup plan (read only) ==")
    enforcement = skills_policy.get("enforceAssignments") is True
    print(f"assignment enforcement: {'enabled' if enforcement else 'disabled (report only)'}")

    agents = skills_policy.get("agents", {})
    if not isinstance(agents, dict):
        print("manage-agents: skills.json agents must be an object", file=sys.stderr)
        return 2
    paths = agent_paths(home)
    canonical_root = Path(os.environ.get("AGENTS_SKILLS_DIR", home / ".agents" / "skills"))

    shared: set[str] = set()
    for config in agents.values():
        if isinstance(config, dict):
            shared.update(safe_names(config.get("shared")))
    missing_canonical = [name for name in sorted(shared) if not (canonical_root / name).exists()]
    print_names("canonical missing", missing_canonical)
    for name in missing_canonical:
        variants: dict[str, list[str]] = {}
        for agent, agent_root in paths.items():
            candidate = agent_root / "skills" / name
            if candidate.exists():
                variants.setdefault(directory_digest(candidate), []).append(agent)
        if len(variants) > 1:
            variant_agents = sorted(agent for group in variants.values() for agent in group)
            print(f"shared variants differ: {name} ({','.join(variant_agents)})")
    unclassified_canonical = sorted(set(names_in(canonical_root)).difference(shared))
    print_names("canonical unclassified", unclassified_canonical)

    for agent in ("pi", "claude", "codex", "hermes"):
        config = agents.get(agent, {})
        if not isinstance(config, dict):
            continue
        skill_root = paths[agent] / "skills"
        for name in safe_names(config.get("shared")):
            canonical = canonical_root / name
            assigned = skill_root / name
            if not assigned.exists():
                print(f"{agent} assigned shared missing: {name}")
            elif canonical.exists() and assigned.resolve() != canonical.resolve():
                kind = "duplicate" if directory_digest(assigned) == directory_digest(canonical) else "divergent"
                print(f"{agent} {kind} shared copy: {name}")
        for name in safe_names(config.get("local")):
            if not (skill_root / name).exists():
                print(f"{agent} local keep missing: {name}")
        present_review = [
            name for name in safe_names(config.get("review")) if (skill_root / name).exists()
        ]
        if present_review:
            print_names(f"{agent} review installed", present_review)
        classified = set(safe_names(config.get("shared")))
        classified.update(safe_names(config.get("local")))
        classified.update(safe_names(config.get("review")))
        unclassified = sorted(set(names_in(skill_root)).difference(classified))
        if unclassified:
            print_names(f"{agent} unclassified installed", unclassified)

    plugin_agents = plugins_policy.get("agents", {})
    if not isinstance(plugin_agents, dict):
        print("manage-agents: plugins.json agents must be an object", file=sys.stderr)
        return 2
    current_plugins = installed_plugins(home, paths)
    for agent in ("pi", "claude", "codex", "hermes"):
        config = plugin_agents.get(agent, {})
        if not isinstance(config, dict):
            continue
        current = current_plugins[agent]
        for name in safe_names(config.get("keep")):
            if name not in current:
                print(f"{agent} plugin keep missing: {name}")
        for name in safe_names(config.get("review")):
            if name in current:
                print(f"{agent} plugin review enabled: {name}")
        classified_plugins = set(safe_names(config.get("keep")))
        classified_plugins.update(safe_names(config.get("review")))
        unclassified_plugins = sorted(current.difference(classified_plugins))
        if unclassified_plugins:
            print_names(f"{agent} plugin unclassified enabled", unclassified_plugins)
    return 0


def inventory(home: Path) -> int:
    paths = agent_paths(home)
    pi_agent = paths["pi"]
    pi_root = pi_agent.parent
    work_slug = os.environ.get("DOTFILES_PI_WORK_PROFILE_SLUG", "work")
    pi_work = pi_root / f"agent-{work_slug}"
    claude = paths["claude"]
    codex = paths["codex"]
    hermes = paths["hermes"]

    print("== agent capability inventory (names only; values omitted) ==")
    print_names("skills.shared", names_in(home / ".agents" / "skills"))
    print_names("skills.pi", names_in(pi_agent / "skills"))
    print_names("skills.claude", names_in(claude / "skills"))
    print_names("skills.codex", names_in(codex / "skills"))
    print_names("skills.hermes", names_in(hermes / "skills"))

    print_names("plugins.pi", names_in(pi_agent / "extensions", file_suffix=".ts"))
    claude_settings = json_object(claude / "settings.json")
    enabled = claude_settings.get("enabledPlugins", {})
    claude_plugins = [
        name for name, state in enabled.items() if isinstance(name, str) and state is True
    ] if isinstance(enabled, dict) else []
    print_names("plugins.claude", claude_plugins)
    hermes_mcp, hermes_plugins = hermes_capabilities(hermes / "config.yaml")
    print_names("plugins.hermes", hermes_plugins)

    pi_mcp = json_object(pi_agent / "mcp.json")
    print_names("mcp.pi-personal", safe_names(pi_mcp.get("mcpServers")))
    work_mcp = json_object(pi_work / "mcp.json")
    print_names("mcp.pi-work", safe_names(work_mcp.get("mcpServers")))

    claude_plugin_mcp: set[str] = set()
    installed_plugin_state = json_object(claude / "plugins" / "installed_plugins.json")
    installed_plugin_records = installed_plugin_state.get("plugins", {})
    for plugin_id in safe_names(claude_plugins):
        if "@" not in plugin_id:
            continue
        plugin_name, marketplace = plugin_id.rsplit("@", 1)
        if not plugin_name or not SAFE_NAME.fullmatch(plugin_name) or not SAFE_NAME.fullmatch(marketplace):
            continue
        plugin_root = claude / "plugins" / "cache" / marketplace / plugin_name
        if not plugin_root.is_dir():
            continue
        records = installed_plugin_records.get(plugin_id, []) if isinstance(installed_plugin_records, dict) else []
        versions = safe_names(
            [record.get("version") for record in records if isinstance(record, dict)]
            if isinstance(records, list)
            else []
        )
        mcp_files = [
            plugin_root / version / ".mcp.json"
            for version in versions
            if (plugin_root / version / ".mcp.json").is_file()
        ]
        if not mcp_files:
            mcp_files = list(plugin_root.glob("*/.mcp.json"))
        for mcp_file in mcp_files:
            plugin_mcp = json_object(mcp_file)
            servers = plugin_mcp.get("mcpServers", plugin_mcp)
            claude_plugin_mcp.update(safe_names(servers))
    print_names("mcp.claude-plugin", sorted(claude_plugin_mcp))

    claude_state = json_object(home / ".claude.json")
    claude_mcp = set(safe_names(claude_state.get("mcpServers")))
    projects = claude_state.get("projects", {})
    if isinstance(projects, dict):
        for project in projects.values():
            if isinstance(project, dict):
                claude_mcp.update(safe_names(project.get("mcpServers")))
    print_names("mcp.claude", sorted(claude_mcp))

    codex_config = toml_object(codex / "config.toml")
    print_names("mcp.codex", safe_names(codex_config.get("mcp_servers")))
    print_names("mcp.hermes", hermes_mcp)
    return 0


def main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else "inventory"
    home = Path.home()
    policy_dir = Path(
        os.environ.get("DOTFILES_AGENT_POLICY_DIR", Path(__file__).resolve().parent.parent / "config" / "agents")
    )
    if command == "inventory":
        return inventory(home)
    if command == "plan":
        return plan(home, policy_dir)
    if command == "check":
        return check(policy_dir)
    print(f"manage-agents: unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
