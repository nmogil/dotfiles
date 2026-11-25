#!/usr/bin/env python3
"""CLI behavior tests using isolated homes and a version-only Pi executable."""
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
        (binary / "pi").write_text("#!/bin/sh\nprintf '1.4.0\\n'\n")
        (binary / "pi").chmod(0o755)
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
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
        binary = self.root / "bin/pi"
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
        (self.root / "bin/pi").write_text(f"#!/bin/sh\nprintf '{version}\\n'\n")

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
        self.set_pi_version("1.4.0-beta.1")
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
        for junk in ("", "1.6", "1.6.0.1", "v1.6.0", "1.6.0-beta.1", " 1.6.0", "1.x.0", None, 160):
            with self.assertRaises(ValueError, msg=repr(junk)):
                self.module.parse(junk)


if __name__ == "__main__":
    unittest.main()
