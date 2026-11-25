#!/usr/bin/env python3
"""CLI behavior tests using isolated homes and a version-only Pi executable."""
import json
import os
from pathlib import Path
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

    def test_version_mismatch_refuses_apply(self):
        self.run_cli("capture", apply=True)
        (self.root / "bin/pi").write_text("#!/bin/sh\nprintf '0.0.1\\n'\n")
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


if __name__ == "__main__":
    unittest.main()
