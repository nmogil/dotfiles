#!/usr/bin/env python3
"""CLI behavior tests using isolated homes and a version-only Pi executable."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "sync-pi-config.py"


class PiConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.mac = self.root / "mac"
        self.vps = self.root / "vps"
        self.bundle = self.root / "private" / "pi-config"
        binary = self.root / "bin"
        binary.mkdir()
        # Pi as a global npm install: <prefix>/bin/pi -> ../lib/node_modules/<pkg>/dist/cli.js.
        # Its version lives in the package's package.json; every launch is logged.
        self.prefix = self.root / "npm"
        self.package = self.prefix / "lib/node_modules/@earendil-works/pi-coding-agent"
        self.launches = self.root / "pi-launches"
        cli = self.package / "dist/cli.js"
        cli.parent.mkdir(parents=True)
        cli.write_text(f"#!/bin/sh\necho \"$*\" >> '{self.launches}'\nprintf '0.0.0-launched\\n'\n")
        cli.chmod(0o755)
        (self.prefix / "bin").mkdir()
        (self.prefix / "bin/pi").symlink_to("../lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
        self.set_pi_version("1.4.0")
        self.env = dict(os.environ, PATH=os.pathsep.join([str(self.prefix / "bin"), str(binary), os.environ["PATH"]]),
                        DOTFILES_PI_BLOCKLIST=str(self.root / "blocklist"))
        self.put(self.mac, ".pi/agent/settings.json", json.dumps({
            "theme": "catppuccin-macchiato", "defaultModel": "test-model",
            "packages": [], "lastChangelogVersion": "local",
        }))
        self.put(self.mac, ".pi/agent/skills/test/SKILL.md", "# Portable skill\n")
        self.put(self.mac, ".pi/agent/extensions/test.ts", "export default () => {};\n")

    def put(self, home, name, content):
        path = home / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def run_cli(self, command, home=None, apply=False, expected=0, extra_args=()):
        args = ["python3", str(SCRIPT), command, "--home", str(home or self.mac), "--bundle", str(self.bundle)]
        if apply:
            args.append("--apply")
        args.extend(extra_args)
        result = subprocess.run(args, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_capture_excludes_state_and_dry_run_writes_nothing(self):
        for name in ("auth.json", "models.json", "mcp.json", "memory-compiler.json", "trust.json"):
            self.put(self.mac, ".pi/agent/" + name, "private-state")
        self.put(self.mac, ".pi/agent/skills/test/SKILL.md.bak.old", "old")
        self.put(self.mac, ".pi/agent-client/auth.json", "work-state")
        self.run_cli("capture")
        self.assertFalse(self.bundle.exists())
        self.run_cli("capture", apply=True)
        manifest = json.loads((self.bundle / "manifest.json").read_text())
        self.assertEqual(len(manifest["files"]), 3)
        settings = json.loads((self.bundle / "files/.pi/agent/settings.json").read_text())
        self.assertNotIn("lastChangelogVersion", settings)

    def test_apply_preserves_machine_state_backs_up_and_is_idempotent(self):
        self.run_cli("capture", apply=True)
        self.put(self.vps, ".pi/agent/auth.json", "remote-credentials")
        self.put(self.vps, ".pi/agent/mcp.json", "remote-mcp")
        self.put(self.vps, ".pi/agent/extensions/vps-safety.ts", "remote-guard")
        self.put(self.vps, ".pi/agent/settings.json", json.dumps({
            "theme": "dark", "lastChangelogVersion": "remote",
            "compaction": {"reserveTokens": 9000}, "shellPath": "/bin/bash",
        }))
        before = (self.vps / ".pi/agent/settings.json").read_bytes()
        self.run_cli("apply", self.vps)
        self.assertEqual((self.vps / ".pi/agent/settings.json").read_bytes(), before)
        self.run_cli("check", self.vps, expected=1)
        self.run_cli("apply", self.vps, apply=True)
        actual = json.loads((self.vps / ".pi/agent/settings.json").read_text())
        self.assertEqual(actual["theme"], "catppuccin-macchiato")
        self.assertEqual(actual["lastChangelogVersion"], "remote")
        self.assertEqual(actual["shellPath"], "/bin/bash")
        self.assertNotIn("compaction", actual)
        self.assertEqual((self.vps / ".pi/agent/auth.json").read_text(), "remote-credentials")
        self.assertEqual((self.vps / ".pi/agent/mcp.json").read_text(), "remote-mcp")
        self.assertEqual((self.vps / ".pi/agent/extensions/vps-safety.ts").read_text(), "remote-guard")
        backups = list((self.vps / ".local/state/dotfiles/pi-config-backups").glob("apply-*/.pi/agent/settings.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)
        self.run_cli("check", self.vps)
        self.run_cli("apply", self.vps, apply=True)
        self.assertEqual(len(list((self.vps / ".local/state/dotfiles/pi-config-backups").iterdir())), 1)

    def test_removed_baseline_files_are_archived_only_when_previously_managed(self):
        self.run_cli("capture", apply=True)
        self.put(self.vps, ".pi/agent/skills/vps-only/SKILL.md", "keep this overlay")
        self.run_cli("apply", self.vps, apply=True)
        (self.mac / ".pi/agent/skills/test/SKILL.md").unlink()
        self.run_cli("capture", apply=True)
        self.run_cli("check", self.vps, expected=1)
        self.run_cli("apply", self.vps, apply=True)
        self.assertFalse((self.vps / ".pi/agent/skills/test").exists())
        self.assertEqual((self.vps / ".pi/agent/skills/vps-only/SKILL.md").read_text(), "keep this overlay")
        archived = list((self.vps / ".local/state/dotfiles/pi-config-backups").glob("apply-*/.pi/agent/skills/test/SKILL.md"))
        self.assertEqual(len(archived), 1)
        self.run_cli("check", self.vps)

    def test_explicit_host_exclusions_persist_and_do_not_install_retired_tools(self):
        self.run_cli("capture", apply=True)
        prefix = ".pi/agent/skills/test"
        self.run_cli("apply", self.vps, apply=True, extra_args=("--exclude", prefix))
        self.assertFalse((self.vps / prefix).exists())
        result = self.run_cli("check", self.vps)
        self.assertIn("Machine-local exclusions: " + prefix, result.stdout)
        self.run_cli("apply", self.vps, apply=True)
        self.assertFalse((self.vps / prefix).exists())
        self.assertTrue((self.vps / ".pi/agent/extensions/test.ts").exists())

    def test_check_verifies_installed_versions_not_only_settings(self):
        self.put(self.mac, ".pi/agent/settings.json", '{"packages":["npm:@example/pi-test@1.2.3"]}')
        self.run_cli("capture", apply=True)
        self.run_cli("apply", self.vps, apply=True)
        result = self.run_cli("check", self.vps, expected=1)
        self.assertIn("installed=missing expected=1.2.3", result.stdout)
        self.put(self.vps, ".pi/agent/npm/node_modules/@example/pi-test/package.json", '{"version":"1.2.2"}')
        result = self.run_cli("check", self.vps, expected=1)
        self.assertIn("installed=1.2.2 expected=1.2.3", result.stdout)
        result = self.run_cli("packages", self.vps)
        self.assertIn("would install npm:@example/pi-test@1.2.3", result.stdout)
        self.put(self.vps, ".pi/agent/npm/node_modules/@example/pi-test/package.json", '{"version":"1.2.3"}')
        self.run_cli("check", self.vps)

    def test_local_extension_runtime_dependencies_must_resolve(self):
        extension = ".pi/agent/extensions/chart"
        self.put(self.mac, extension + "/index.ts", "export default () => {};\n")
        self.put(self.mac, extension + "/package.json", json.dumps({
            "dependencies": {"chart-lib": "github:example/chart-lib#abc123"},
            "devDependencies": {"typescript": "^5"},
        }))
        self.run_cli("capture", apply=True)
        self.run_cli("apply", self.vps, apply=True)
        result = self.run_cli("check", self.vps, expected=1)
        self.assertIn(f"extension dependency drift: {extension} missing chart-lib", result.stdout)
        result = self.run_cli("packages", self.vps)
        self.assertIn("would npm install in " + extension, result.stdout)
        # A fake npm records where it ran; packages --apply must use the extension dir.
        npm = self.root / "bin/npm"
        npm.write_text("#!/bin/sh\npwd > \"$(dirname \"$0\")/npm-cwd\"\n")
        npm.chmod(0o755)
        # Never run npm against a local manifest that differs from the baseline.
        baseline = (self.vps / extension / "package.json").read_bytes()
        self.put(self.vps, extension + "/package.json", '{"dependencies":{"chart-lib":"1"}}')
        result = self.run_cli("packages", self.vps, apply=True, expected=2)
        self.assertIn("run apply --apply before installing", result.stderr)
        self.assertFalse((npm.parent / "npm-cwd").exists())
        (self.vps / extension / "package.json").write_bytes(baseline)
        self.run_cli("packages", self.vps, apply=True)
        # Compare resolved paths: macOS temp dirs live behind the /var -> /private/var symlink.
        self.assertEqual(Path((npm.parent / "npm-cwd").read_text().strip()).resolve(),
                         (self.vps / extension).resolve())
        # Dev-only dependencies are not required; a hoisted, symlinked workspace
        # install resolves, and apply never probes dependencies.
        self.put(self.vps, ".pi/workspace/chart-lib/package.json", "{}")
        (self.vps / ".pi/node_modules").mkdir(parents=True)
        (self.vps / ".pi/node_modules/chart-lib").symlink_to(self.vps / ".pi/workspace/chart-lib")
        self.run_cli("check", self.vps)
        self.run_cli("apply", self.vps, apply=True)
        # Ancestor manifests must not satisfy traversal-shaped dependency names.
        self.put(self.vps, ".pi/node_modules/package.json", "{}")
        for invalid in ('{"dependencies":{"..":"1"}}', '{"dependencies":{"@scope/..":"1"}}',
                        '{"dependencies":{"../escape":"1"}}', '{"dependencies":["x"]}', '[1]', 'not json'):
            self.put(self.mac, extension + "/package.json", invalid)
            self.run_cli("capture", apply=True)
            result = self.run_cli("check", self.vps, expected=2)
            self.assertIn("invalid extension", result.stderr)

    def test_compaction_can_float_without_weakening_other_package_pins(self):
        source = "npm:@ogulcancelik/pi-codex-compaction"
        self.put(self.mac, ".pi/agent/settings.json", json.dumps({"packages": [source]}))
        self.run_cli("capture", apply=True)
        self.run_cli("apply", self.vps, apply=True)
        self.run_cli("check", self.vps, expected=1)  # Still requires installation.
        package = ".pi/agent/npm/node_modules/@ogulcancelik/pi-codex-compaction/package.json"
        for version in ("0.1.7", "0.1.8"):
            self.put(self.vps, package, json.dumps({"version": version}))
            self.run_cli("check", self.vps)
        result = self.run_cli("packages", self.vps)
        self.assertIn("would install " + source, result.stdout)
        # An explicit package refresh must run even when a floating package exists.
        binary = self.prefix / "bin/pi"  # writes through the symlink to dist/cli.js
        binary.write_text("#!/usr/bin/env python3\nimport json, pathlib, sys\n"
                          "if sys.argv[1:] == ['--version']: print('1.4.0')\n"
                          "else: pathlib.Path(__file__).with_name('calls.json').write_text(json.dumps(sys.argv[1:]))\n")
        self.run_cli("packages", self.vps, apply=True)
        calls = json.loads((binary.parent / "calls.json").read_text())
        self.assertEqual(calls, ["install", source, "--no-approve"])
        settings = json.loads((self.vps / ".pi/agent/settings.json").read_text())
        self.assertEqual(settings["packages"], [source])
        for rejected in ("npm:test", "npm:test@latest", source + "@latest"):
            self.put(self.mac, ".pi/agent/settings.json", json.dumps({"packages": [rejected]}))
            self.run_cli("capture", expected=2)

    def test_retirement_preserves_unmanaged_siblings(self):
        self.run_cli("capture", apply=True)
        self.run_cli("apply", self.vps, apply=True)
        self.put(self.vps, ".pi/agent/skills/test/local-note.txt", "keep")
        (self.mac / ".pi/agent/skills/test/SKILL.md").unlink()
        self.run_cli("capture", apply=True)
        self.run_cli("apply", self.vps, apply=True)
        self.assertEqual((self.vps / ".pi/agent/skills/test/local-note.txt").read_text(), "keep")

    def set_pi_version(self, version):
        (self.package / "package.json").write_text(json.dumps(
            {"name": "@earendil-works/pi-coding-agent", "version": version}, indent="\t"))

    def test_read_only_commands_never_launch_pi(self):
        # Pi's entry point can write (compile cache, settings lock) even for --version,
        # so read-only paths read the installed package.json instead.
        self.run_cli("capture")
        self.run_cli("capture", apply=True)
        self.launches.unlink(missing_ok=True)
        self.run_cli("apply", self.vps)
        self.run_cli("packages", self.vps)
        self.run_cli("check", self.vps, expected=1)
        self.run_cli("apply", self.vps, apply=True)
        self.run_cli("check", self.vps)
        self.assertFalse(self.launches.exists(), self.launches.read_text() if self.launches.exists() else "")

    def test_unreadable_pi_metadata_is_reported_not_guessed(self):
        self.run_cli("capture", apply=True)
        (self.package / "package.json").write_text("{not json")
        result = self.run_cli("apply", self.vps)
        self.assertIn("Pi CLI: version gate not previewed", result.stdout)
        self.assertIn("minimum 1.4.0", result.stdout)
        self.run_cli("apply", self.vps, apply=True, expected=2)
        self.assertFalse(self.vps.exists())
        self.run_cli("check", self.vps, expected=2)
        (self.package / "package.json").unlink()
        self.assertIn("version gate not previewed", self.run_cli("packages", self.vps).stdout)
        self.assertFalse(self.launches.exists())

    def test_pi_outside_a_global_npm_install_is_refused(self):
        self.run_cli("capture", apply=True)
        other = self.root / "other"
        other.mkdir()
        (other / "pi").write_text("#!/bin/sh\nprintf '1.4.0\\n'\n")
        (other / "pi").chmod(0o755)
        self.env["PATH"] = str(other) + os.pathsep + self.env["PATH"]
        result = self.run_cli("apply", self.vps, apply=True, expected=2)
        self.assertIn("global npm install", result.stderr)
        self.assertFalse(self.vps.exists())

    def test_capture_records_the_installed_package_version(self):
        self.set_pi_version("1.10.2")
        self.run_cli("capture", apply=True)
        self.assertEqual(json.loads((self.bundle / "manifest.json").read_text())["piVersion"], "1.10.2")
        self.set_pi_version("1.10")
        self.run_cli("capture", expected=2)
        self.assertFalse(self.launches.exists())

    def test_manifest_minimum_uses_the_shared_version_grammar(self):
        self.run_cli("capture", apply=True)
        manifest_path = self.bundle / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        for bad in ("1.4.0-beta.1", "1234567.0.0", "\u0661.4.0", "1.4"):
            manifest["piVersion"] = bad
            manifest_path.write_text(json.dumps(manifest))
            result = self.run_cli("check", self.vps, expected=2)
            self.assertIn("invalid Pi baseline manifest", result.stderr)

    def test_older_pi_than_the_minimum_refuses_apply(self):
        self.run_cli("capture", apply=True)  # manifest piVersion (the minimum) = 1.4.0
        self.set_pi_version("1.3.9")
        result = self.run_cli("apply", self.vps, apply=True, expected=2)
        self.assertFalse(self.vps.exists())
        self.assertIn("Pi CLI: 1.3.9 (minimum 1.4.0)", result.stdout)
        self.assertIn("older than the minimum 1.4.0", result.stderr)
        self.assertIn("pi update", result.stderr)
        self.assertNotIn("baseline version", result.stdout + result.stderr)

    def test_newer_pi_than_the_minimum_is_accepted(self):
        self.run_cli("capture", apply=True)
        self.set_pi_version("1.4.1")
        result = self.run_cli("apply", self.vps, apply=True)
        self.assertIn("Pi CLI: 1.4.1 (minimum 1.4.0)", result.stdout)
        self.assertTrue((self.vps / ".pi/agent/extensions/test.ts").exists())
        self.run_cli("check", self.vps)

    def test_pi_equal_to_the_minimum_is_accepted(self):
        self.run_cli("capture", apply=True)
        result = self.run_cli("apply", self.vps, apply=True)
        self.assertIn("Pi CLI: 1.4.0 (minimum 1.4.0)", result.stdout)

    def test_minimum_compares_numerically_not_lexically(self):
        self.set_pi_version("1.9.0")
        self.run_cli("capture", apply=True)  # minimum 1.9.0
        self.set_pi_version("1.10.0")
        self.run_cli("apply", self.vps, apply=True)
        manifest = json.loads((self.bundle / "manifest.json").read_text())
        manifest["piVersion"] = "1.10.0"
        (self.bundle / "manifest.json").write_text(json.dumps(manifest))
        self.set_pi_version("1.9.0")
        self.run_cli("check", self.vps, expected=2)

    def test_unparsable_installed_version_is_refused(self):
        self.run_cli("capture", apply=True)
        for junk in ("1.4.0-beta.1", "1234567.0.0", "\u0661.\u0664.0"):
            self.set_pi_version(junk)
            self.run_cli("apply", self.vps, apply=True, expected=2)
            self.assertFalse(self.vps.exists())

    def test_tampered_bundle_fails_before_any_writes(self):
        self.run_cli("capture", apply=True)
        (self.bundle / "files/.pi/agent/extensions/test.ts").write_text("tampered")
        self.run_cli("apply", self.vps, apply=True, expected=2)
        self.assertFalse(self.vps.exists())

    def test_symlink_source_and_destination_are_rejected(self):
        link = self.mac / ".pi/agent/extensions/linked.ts"
        link.symlink_to(self.mac / ".pi/agent/settings.json")
        self.run_cli("capture", apply=True, expected=2)
        self.assertFalse(self.bundle.exists())
        link.unlink()
        self.run_cli("capture", apply=True)
        outside = self.root / "outside"
        outside.mkdir()
        self.vps.mkdir()
        (self.vps / ".pi").symlink_to(outside)
        self.run_cli("apply", self.vps, apply=True, expected=2)
        self.assertEqual(list(outside.iterdir()), [])

    def test_manifest_cannot_target_credentials_or_traverse(self):
        for name in (".pi/agent/auth.json", "../escape", "/absolute"):
            self.run_cli("capture", apply=True)
            manifest_path = self.bundle / "manifest.json"
            manifest = json.loads(manifest_path.read_text())
            manifest["files"][name] = "bad"
            manifest_path.write_text(json.dumps(manifest))
            self.run_cli("apply", self.vps, apply=True, expected=2)
            self.assertFalse(self.vps.exists())

    def test_private_blocklist_is_honored_without_printing_values(self):
        (self.root / "blocklist").write_text("private-endpoint-fixture\n")
        self.put(self.mac, ".pi/agent/skills/test/private.txt", "private-endpoint-fixture")
        result = self.run_cli("capture", apply=True, expected=2)
        self.assertNotIn("private-endpoint-fixture", result.stderr)
        self.assertFalse(self.bundle.exists())

    def test_package_minimums_refuse_older_pins_everywhere(self):
        name = "@juicesharp/rpiv-ask-user-question"
        package = f".pi/agent/npm/node_modules/{name}/package.json"
        # Capture refuses a live pin below the minimum, prerelease of it included.
        for old in ("2.15.0", "2.16.0-beta.1", "1.99.99"):
            self.put(self.mac, ".pi/agent/settings.json", json.dumps({"packages": [f"npm:{name}@{old}"]}))
            result = self.run_cli("capture", apply=True, expected=2)
            self.assertIn(f"package minimum: {name}@{old} is older than 2.16.0", result.stderr)
            self.assertFalse(self.bundle.exists())
        # Equal and newer (numerically, not lexically) are accepted.
        for ok in ("2.16.0", "2.16.1", "2.100.0", "3.0.0-rc.1"):
            self.put(self.mac, ".pi/agent/settings.json", json.dumps({"packages": [f"npm:{name}@{ok}"]}))
            self.run_cli("capture")
        self.run_cli("capture", apply=True)
        self.run_cli("apply", self.vps, apply=True)
        self.put(self.vps, package, '{"version":"3.0.0-rc.1"}')
        self.run_cli("check", self.vps)
        # A baseline someone edited below the minimum is refused by apply and
        # check, before anything is written.
        settings = self.bundle / "files/.pi/agent/settings.json"
        manifest = json.loads((self.bundle / "manifest.json").read_text())
        old = settings.read_text().replace("3.0.0-rc.1", "2.15.0")
        settings.write_text(old)
        manifest["files"][".pi/agent/settings.json"] = hashlib.sha256(old.encode()).hexdigest()
        (self.bundle / "manifest.json").write_text(json.dumps(manifest))
        before = (self.vps / ".pi/agent/settings.json").read_text()
        for command, apply in (("check", False), ("apply", True)):
            result = self.run_cli(command, self.vps, apply=apply, expected=2)
            self.assertIn("is older than 2.16.0", result.stderr)
        self.assertEqual((self.vps / ".pi/agent/settings.json").read_text(), before)
        # Packages without a minimum keep working at any exact version.
        self.put(self.mac, ".pi/agent/settings.json", '{"packages":["npm:@example/pi-test@0.0.1"]}')
        self.run_cli("capture")

    def test_live_secrets_and_unpinned_packages_are_rejected(self):
        secret = self.put(self.mac, ".pi/agent/skills/test/key.txt", "sk-ant-" + "a" * 30)
        self.run_cli("capture", apply=True, expected=2)
        self.assertFalse(self.bundle.exists())
        secret.unlink()
        for prefix in ("ghp_", "github_pat_", "sk-"):
            self.put(self.mac, ".pi/agent/skills/test/key.txt", prefix + "a" * 40)
            self.run_cli("capture", apply=True, expected=2)
            self.assertFalse(self.bundle.exists())
        secret.unlink()
        self.put(self.mac, ".pi/agent/settings.json", '{"packages":["npm:test@latest"]}')
        self.run_cli("capture", apply=True, expected=2)
        self.assertFalse(self.bundle.exists())


    # --protect-local (used by ./dot update): never overwrite or archive a live
    # file that differs from the incoming baseline unless it matched the
    # previous baseline (i.e. it holds no local change).
    def tree(self, home):
        return {str(p.relative_to(home)): p.read_bytes() for p in sorted(home.rglob("*")) if p.is_file()}

    def synced_previous(self):
        self.run_cli("capture", apply=True)
        previous = self.root / "previous"
        shutil.copytree(self.bundle, previous)
        self.run_cli("apply", self.vps, apply=True)
        return previous

    def protect(self, previous=None):
        args = ["--protect-local"]
        if previous is not None:
            args += ["--previous-bundle", str(previous)]
        return tuple(args)

    def test_protect_local_upgrades_from_a_previous_baseline_below_a_minimum(self):
        # ./dot update compares against the baseline this machine last applied,
        # which may predate a package minimum. Only the incoming one must meet it.
        name = "@juicesharp/rpiv-ask-user-question"
        self.put(self.mac, ".pi/agent/settings.json", json.dumps({"packages": [f"npm:{name}@2.16.0"]}))
        self.run_cli("capture", apply=True)
        previous = self.root / "previous"
        shutil.copytree(self.bundle, previous)
        settings = previous / "files/.pi/agent/settings.json"
        old = settings.read_text().replace("2.16.0", "2.15.0")
        settings.write_text(old)
        manifest = json.loads((previous / "manifest.json").read_text())
        manifest["files"][".pi/agent/settings.json"] = hashlib.sha256(old.encode()).hexdigest()
        (previous / "manifest.json").write_text(json.dumps(manifest))
        self.run_cli("apply", self.vps, apply=True)
        self.put(self.vps, ".pi/agent/settings.json", old)  # what the old baseline left behind
        self.run_cli("apply", self.vps, apply=True, extra_args=self.protect(previous))
        live = json.loads((self.vps / ".pi/agent/settings.json").read_text())
        self.assertEqual(live["packages"], [f"npm:{name}@2.16.0"])

    def test_protect_local_refuses_newly_managed_file_that_differs(self):
        previous = self.synced_previous()
        self.put(self.mac, ".pi/agent/extensions/new.ts", "export const fromMac = 1;\n")
        self.run_cli("capture", apply=True)
        self.put(self.vps, ".pi/agent/extensions/new.ts", "export const mine = 2;\n")
        before = self.tree(self.vps)
        result = self.run_cli("apply", self.vps, apply=True, expected=3, extra_args=self.protect(previous))
        self.assertIn("local change  .pi/agent/extensions/new.ts", result.stdout)
        self.assertEqual(self.tree(self.vps), before)
        preview = self.run_cli("apply", self.vps, expected=3, extra_args=self.protect(previous))
        self.assertIn("local change  .pi/agent/extensions/new.ts", preview.stdout)
        self.assertEqual(self.tree(self.vps), before)
        self.run_cli("apply", self.vps, apply=True)  # without the guard: unchanged behavior
        self.assertEqual((self.vps / ".pi/agent/extensions/new.ts").read_text(), "export const fromMac = 1;\n")

    def test_protect_local_allows_new_absent_or_identical_files_and_clean_updates(self):
        previous = self.synced_previous()
        self.put(self.mac, ".pi/agent/extensions/new.ts", "export const fromMac = 1;\n")
        self.put(self.mac, ".pi/agent/extensions/same.ts", "export const same = 1;\n")
        self.put(self.mac, ".pi/agent/extensions/test.ts", "export default () => 2;\n")
        settings = json.loads((self.mac / ".pi/agent/settings.json").read_text())
        settings["theme"] = "dark"
        self.put(self.mac, ".pi/agent/settings.json", json.dumps(settings))
        self.run_cli("capture", apply=True)
        self.put(self.vps, ".pi/agent/extensions/same.ts", "export const same = 1;\n")
        self.run_cli("apply", self.vps, apply=True, extra_args=self.protect(previous))
        self.assertEqual((self.vps / ".pi/agent/extensions/new.ts").read_text(), "export const fromMac = 1;\n")
        self.assertEqual((self.vps / ".pi/agent/extensions/test.ts").read_text(), "export default () => 2;\n")
        self.assertEqual(json.loads((self.vps / ".pi/agent/settings.json").read_text())["theme"], "dark")
        self.run_cli("check", self.vps)

    def test_protect_local_refuses_locally_edited_managed_files(self):
        previous = self.synced_previous()
        self.put(self.mac, ".pi/agent/extensions/test.ts", "export default () => 2;\n")
        self.run_cli("capture", apply=True)
        self.put(self.vps, ".pi/agent/extensions/test.ts", "export default () => 'vps edit';\n")
        settings = json.loads((self.vps / ".pi/agent/settings.json").read_text())
        settings["theme"] = "vps-theme"
        self.put(self.vps, ".pi/agent/settings.json", json.dumps(settings))
        before = self.tree(self.vps)
        result = self.run_cli("apply", self.vps, apply=True, expected=3, extra_args=self.protect(previous))
        self.assertIn("local change  .pi/agent/extensions/test.ts", result.stdout)
        self.assertIn("local change  .pi/agent/settings.json", result.stdout)
        self.assertEqual(self.tree(self.vps), before)

    def test_protect_local_refuses_archiving_a_locally_edited_retired_file(self):
        previous = self.synced_previous()
        (self.mac / ".pi/agent/skills/test/SKILL.md").unlink()
        self.run_cli("capture", apply=True)
        self.put(self.vps, ".pi/agent/skills/test/SKILL.md", "# edited on the vps\n")
        result = self.run_cli("apply", self.vps, apply=True, expected=3, extra_args=self.protect(previous))
        self.assertIn("local change  .pi/agent/skills/test/SKILL.md", result.stdout)
        self.assertEqual((self.vps / ".pi/agent/skills/test/SKILL.md").read_text(), "# edited on the vps\n")
        self.put(self.vps, ".pi/agent/skills/test/SKILL.md", "# Portable skill\n")
        self.run_cli("apply", self.vps, apply=True, extra_args=self.protect(previous))
        self.assertFalse((self.vps / ".pi/agent/skills/test").exists())

    def test_protect_local_treats_a_deleted_managed_file_as_a_local_change(self):
        previous = self.synced_previous()
        self.put(self.mac, ".pi/agent/extensions/other.ts", "export const other = 1;\n")
        self.run_cli("capture", apply=True)
        (self.vps / ".pi/agent/extensions/test.ts").unlink()
        before = self.tree(self.vps)
        result = self.run_cli("apply", self.vps, apply=True, expected=3, extra_args=self.protect(previous))
        self.assertIn("local change  .pi/agent/extensions/test.ts", result.stdout)
        self.assertNotIn("local change  .pi/agent/extensions/other.ts", result.stdout)
        self.assertEqual(self.tree(self.vps), before)
        self.assertFalse((self.vps / ".pi/agent/extensions/test.ts").exists())

    def test_protect_local_without_previous_baseline_protects_every_differing_live_file(self):
        self.run_cli("capture", apply=True)
        self.put(self.vps, ".pi/agent/extensions/test.ts", "export default () => 'vps';\n")
        result = self.run_cli("apply", self.vps, apply=True, expected=3, extra_args=self.protect())
        self.assertIn("local change  .pi/agent/extensions/test.ts", result.stdout)
        self.assertFalse((self.vps / ".pi/agent/skills/test/SKILL.md").exists())
        (self.vps / ".pi/agent/extensions/test.ts").unlink()
        self.run_cli("apply", self.vps, apply=True, extra_args=self.protect())
        self.assertTrue((self.vps / ".pi/agent/skills/test/SKILL.md").exists())

    def test_protect_local_flags_are_apply_only(self):
        self.run_cli("capture", apply=True)
        self.run_cli("check", self.vps, expected=2, extra_args=("--protect-local",))
        self.run_cli("apply", self.vps, expected=2, extra_args=("--previous-bundle", str(self.bundle)))


class PiVersionHelperTest(unittest.TestCase):
    """The one Python version-compare helper (scripts/lib/pi_version.py)."""

    @classmethod
    def setUpClass(cls):
        import importlib.util
        import sys
        path = SCRIPT.parent / "lib" / "pi_version.py"
        spec = importlib.util.spec_from_file_location("pi_version", path)
        cls.module = importlib.util.module_from_spec(spec)
        dont_write = sys.dont_write_bytecode
        sys.dont_write_bytecode = True
        try:
            spec.loader.exec_module(cls.module)
        finally:
            sys.dont_write_bytecode = dont_write

    def test_at_least(self):
        at_least = self.module.at_least
        for installed, minimum in (("1.6.0", "1.6.0"), ("1.6.1", "1.6.0"), ("1.7.0", "1.6.9"),
                                   ("2.0.0", "1.99.99"), ("1.10.0", "1.9.0"), ("1.6.10", "1.6.9")):
            self.assertTrue(at_least(installed, minimum), (installed, minimum))
        for installed, minimum in (("1.5.9", "1.6.0"), ("1.6.0", "1.6.1"), ("1.9.0", "1.10.0"),
                                   ("0.81.1", "1.6.0")):
            self.assertFalse(at_least(installed, minimum), (installed, minimum))

    def test_parse_rejects_non_release_versions(self):
        self.assertEqual(self.module.parse("1.10.0"), (1, 10, 0))
        self.assertEqual(self.module.parse("999999.0.08"), (999999, 0, 8))
        for junk in ("", "1.6", "1.6.0.1", "v1.6.0", "1.6.0-beta.1", " 1.6.0", "1.6.0\n", "1.x.0", None, 160,
                     "1234567.0.0", "1.0.1234567", "\u0661.\u0666.\u0660", "1.\uff16.0", "+1.6.0", "1._6.0"):
            with self.assertRaises(ValueError, msg=repr(junk)):
                self.module.parse(junk)

    def make_install(self, root, prefix_rel, bin_rel=None, package_rel=None, version="1.6.1"):
        """Build <root>/<prefix_rel>/lib/node_modules/<pkg> (or package_rel) and a bin/pi symlink."""
        root = Path(root)
        package = root / (package_rel or f"{prefix_rel}/lib/node_modules/@earendil-works/pi-coding-agent")
        cli = package / "dist/bundle/cli.js"
        cli.parent.mkdir(parents=True, exist_ok=True)
        cli.write_text("#!/bin/sh\nexit 99\n")
        cli.chmod(0o755)
        (package / "package.json").write_text(json.dumps({"name": "@earendil-works/pi-coding-agent", "version": version}))
        pi = root / (bin_rel or f"{prefix_rel}/bin/pi")
        pi.parent.mkdir(parents=True, exist_ok=True)
        pi.symlink_to(os.path.relpath(cli, pi.parent))
        return pi

    def test_installed_version_reads_package_json_of_a_global_npm_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            pi = self.make_install(tmp, "usr")
            self.assertEqual(self.module.installed_version(str(pi)), "1.6.1")
            # The same install reached through a symlinked PATH directory still counts.
            (Path(tmp) / "linkbin").symlink_to(Path(tmp) / "usr/bin")
            self.assertEqual(self.module.installed_version(str(Path(tmp) / "linkbin/pi")), "1.6.1")

    def test_installed_version_rejects_unsupported_layouts(self):
        not_npm = self.module.NotNpmLayout
        with tempfile.TemporaryDirectory() as tmp:
            cases = {
                "project-local": self.make_install(
                    tmp, "", bin_rel="proj/node_modules/.bin/pi",
                    package_rel="proj/node_modules/@earendil-works/pi-coding-agent"),
                "project under lib": self.make_install(
                    tmp, "", bin_rel="code/lib/node_modules/.bin/pi",
                    package_rel="code/lib/node_modules/@earendil-works/pi-coding-agent"),
                "pnpm": self.make_install(
                    tmp, "", bin_rel="pnpm/bin/pi",
                    package_rel="pnpm/global/5/node_modules/.pnpm/@earendil-works+pi-coding-agent@1.6.1/"
                                "node_modules/@earendil-works/pi-coding-agent"),
                "vite-plus": self.make_install(tmp, ".vite-plus"),
                "bin outside the prefix": self.make_install(
                    tmp, "elsewhere", bin_rel="stray/pi"),
            }
            for name, pi in cases.items():
                with self.assertRaises(not_npm, msg=name):
                    self.module.installed_version(str(pi))
            plain = Path(tmp) / "plain/pi"
            plain.parent.mkdir()
            plain.write_text("#!/bin/sh\necho 1.6.1\n")
            plain.chmod(0o755)
            with self.assertRaises(not_npm):
                self.module.installed_version(str(plain))
            good = self.make_install(tmp, "good")
            with self.assertRaises(not_npm):  # relative paths are never trusted
                self.module.installed_version(os.path.relpath(good))
            with self.assertRaises(not_npm):
                self.module.installed_version(str(Path(tmp) / "missing/bin/pi"))

    def test_installed_version_requires_a_verified_pi_manifest(self):
        unavailable, not_npm = self.module.MetadataUnavailable, self.module.NotNpmLayout
        with tempfile.TemporaryDirectory() as tmp:
            pi = self.make_install(tmp, "usr")
            package_json = Path(tmp) / "usr/lib/node_modules/@earendil-works/pi-coding-agent/package.json"
            # Only a manifest verified as @earendil-works/pi-coding-agent with an
            # unreadable version is "metadata unavailable"...
            for version in ("1.6", None, 160, "1.6.0-beta.1"):
                package_json.write_text(json.dumps({"name": "@earendil-works/pi-coding-agent", "version": version}))
                with self.assertRaises(unavailable, msg=version):
                    self.module.installed_version(str(pi))
            # ...anything that does not prove it is that package is not the install.
            for content in ("{broken", "[]", json.dumps({"name": "other", "version": "1.6.1"}),
                            json.dumps({"version": "1.6.1"}), b"\xff\xfe"):
                if isinstance(content, bytes):
                    package_json.write_bytes(content)
                else:
                    package_json.write_text(content)
                with self.assertRaises(not_npm, msg=content):
                    self.module.installed_version(str(pi))
            package_json.unlink()
            with self.assertRaises(not_npm):
                self.module.installed_version(str(pi))


if __name__ == "__main__":
    unittest.main()
