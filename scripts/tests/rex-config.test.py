#!/usr/bin/env python3
"""Installer behavior tests against the actual Mac Rex config validator."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
REX = os.environ.get('REX_BIN') or shutil.which('rex') or str(
    Path.home()/'Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex'
)


@unittest.skipUnless(os.uname().sysname == 'Darwin' and Path(REX).is_file(), 'requires Mac Rex CLI')
class RexConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)/'home'
        self.home.mkdir()
        self.config = self.home/'.config/rex'
        self.env = dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME=str(self.home/'.config'), REX_BIN=REX)
        for name in ('REX_CONFIG', 'DOTFILES_REX_OVERLAY_DIR', 'DOTFILES_PI_SCAFFOLD_DIR', 'DOTFILES_LOCAL_ENV'):
            self.env.pop(name, None)

    def make_overlay(self, files):
        overlay = Path(self.tmp.name)/'private/rex'
        for relative, text in files.items():
            (overlay/relative).parent.mkdir(parents=True, exist_ok=True)
            (overlay/relative).write_text(text)
        self.env['DOTFILES_REX_OVERLAY_DIR'] = str(overlay)
        return overlay

    def snapshot(self, root=None):
        root = root or self.config
        if not root.exists():
            return None
        return {str(p.relative_to(root)): (p.read_bytes(), p.stat().st_mtime_ns)
                for p in sorted(root.rglob('*')) if p.is_file()}

    def run_setup(self, *args, script=None, expected=0):
        result = subprocess.run(['/bin/bash', str(script or ROOT/'scripts/setup-rex-config.sh'), *args],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout+result.stderr)
        return result

    def test_dry_run_and_check_never_create_configs(self):
        self.run_setup()
        self.assertFalse(self.config.exists())
        self.run_setup('--check', expected=1)
        self.assertFalse(self.config.exists())

    def test_apply_is_idempotent_and_check_detects_drift(self):
        self.run_setup('--apply')
        installed = {str(p.relative_to(self.config)): (p.read_bytes(), p.stat().st_mtime_ns)
                     for p in self.config.rglob('*') if p.is_file()}
        self.assertEqual(len(installed), 6)
        self.run_setup('--check')
        self.run_setup('--apply')
        self.run_setup('--dry-run')
        self.assertEqual(installed, {str(p.relative_to(self.config)): (p.read_bytes(), p.stat().st_mtime_ns)
                                    for p in self.config.rglob('*') if p.is_file()})
        with (self.config/'init.lua').open('a') as f:
            f.write('-- local change\n')
        self.run_setup('--check', expected=1)

    def test_conflicts_fail_before_copy_and_force_preserves_backup(self):
        self.config.mkdir(parents=True)
        original = 'rex.bind("cmd+d", "pane.split")\n'
        (self.config/'init.lua').write_text(original)
        (self.config/'keep.lua').write_text('-- unrelated file\n')
        preview = self.run_setup().stdout
        self.assertIn(f'would replace {self.config/"init.lua"} (differs; --apply needs --force', preview)
        self.assertIn(f'would install {self.config/"rex-image-paste/init.lua"}', preview)
        self.run_setup('--apply', expected=1)
        self.assertFalse((self.config/'rex-image-paste').exists())
        self.assertEqual((self.config/'init.lua').read_text(), original)
        self.run_setup('--apply', '--force')
        backups = list((self.home/'.local/state/dotfiles/rex-backups').glob('apply-*/init.lua'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), original)
        self.assertEqual((self.config/'keep.lua').read_text(), '-- unrelated file\n')
        self.run_setup('--check')

    def test_symlink_destinations_are_not_overwritten(self):
        self.config.mkdir(parents=True)
        outside = self.home/'outside.lua'
        outside.write_text('-- keep me\n')
        (self.config/'init.lua').symlink_to(outside)
        self.run_setup('--apply', '--force', expected=1)
        self.assertEqual(outside.read_text(), '-- keep me\n')
        (self.config/'init.lua').unlink()
        outside_dir = self.home/'outside-dir'
        outside_dir.mkdir()
        (self.config/'rex-image-paste').symlink_to(outside_dir)
        self.run_setup('--apply', expected=1)
        self.assertEqual(list(outside_dir.iterdir()), [])

    def test_vendor_checksum_failure_prevents_installation(self):
        fixture = Path(self.tmp.name)/'repo'
        (fixture/'scripts/lib').mkdir(parents=True)
        shutil.copytree(ROOT/'config/rex', fixture/'config/rex')
        shutil.copy2(ROOT/'scripts/setup-rex-config.sh', fixture/'scripts/setup-rex-config.sh')
        shutil.copy2(ROOT/'scripts/lib/local-env.sh', fixture/'scripts/lib/local-env.sh')
        (fixture/'config/rex/rex-image-paste/init.lua').write_text('error("must not execute")\n')
        result = self.run_setup('--apply', script=fixture/'scripts/setup-rex-config.sh', expected=1)
        self.assertIn('init.lua: FAILED', result.stdout + result.stderr)
        self.assertIn('did NOT match', result.stdout + result.stderr)
        self.assertNotIn('must not execute', result.stdout + result.stderr)
        self.assertFalse(self.config.exists())

    # --- private overlay -------------------------------------------------

    OVERLAY_ACTION = 'rex.action({ name = "overlay_probe", title = "Probe", run = function() end })\n'

    def test_overlay_is_installed_beside_init_and_loaded(self):
        self.make_overlay({
            'dotfiles_private.lua': 'require("probe_pkg")\n',
            'probe_pkg/init.lua': self.OVERLAY_ACTION,
            'README.md': 'docs only\n',
            'targets.example.json': '{}\n',
        })
        result = self.run_setup('--apply')
        self.assertIn('Private overlay:', result.stdout)
        self.assertTrue((self.config/'dotfiles_private.lua').is_file())
        self.assertTrue((self.config/'probe_pkg/init.lua').is_file())
        self.assertFalse((self.config/'README.md').exists())
        self.assertFalse((self.config/'targets.example.json').exists())
        check = self.run_setup('--check')
        self.assertIn('actions: 2', check.stdout + check.stderr)  # image_paste + overlay_probe

    def test_overlay_can_also_come_from_the_scaffold_sibling(self):
        overlay = self.make_overlay({'dotfiles_private.lua': self.OVERLAY_ACTION})
        del self.env['DOTFILES_REX_OVERLAY_DIR']
        self.env['DOTFILES_PI_SCAFFOLD_DIR'] = str(overlay.parent/'pi-scaffold')
        self.run_setup('--apply')
        self.assertTrue((self.config/'dotfiles_private.lua').is_file())

    def test_pi_resume_trust_rules_are_in_force(self):
        # Rex runs a reported resume command only if a rule trusts it; Pi needs ours.
        T = Path(self.tmp.name) / 'check'
        shutil.copytree(ROOT / 'config/rex', T)
        r = subprocess.run([REX, 'config', 'check', str(T / 'init.lua')], capture_output=True, text=True,
                           env=dict(self.env, REX_CONFIG=str(T / 'init.lua')))
        out = r.stdout + r.stderr
        if 'resume rules' not in out:
            self.skipTest('this Rex has no resume rules')
        self.assertEqual(r.returncode, 0, out)
        self.assertIn('command: pi --session <uuid>', out)
        self.assertIn('command: pi --agent-dir <path under ~/.pi> --session <uuid>', out)
        self.assertIn('command: pi --agent-dir <path under ~/.pi> --session-dir <path under ~/.pi> --session <uuid>', out)

    def test_init_without_overlay_still_validates(self):
        self.run_setup('--apply')
        self.assertFalse((self.config/'dotfiles_private.lua').exists())
        self.run_setup('--check')

    def test_broken_overlay_fails_the_check(self):
        self.make_overlay({'dotfiles_private.lua': 'require("missing_dependency")\n'})
        self.run_setup('--apply', expected=1)  # staged config check fails loudly
        self.assertFalse(self.config.exists())  # nothing was installed
        self.config.mkdir(parents=True)
        (self.config/'keep.lua').write_text('-- unrelated file\n')
        before = self.snapshot()
        result = self.run_setup('--apply', expected=1)
        self.assertIn('nothing installed', result.stderr)
        self.assertEqual(self.snapshot(), before)  # DEST not modified

    def test_staged_check_sees_existing_destination_files(self):
        # The overlay may rely on files that stay in DEST (machine-local modules).
        self.make_overlay({'dotfiles_private.lua': 'require("machine_local")\n'})
        self.config.mkdir(parents=True)
        (self.config/'machine_local.lua').write_text(self.OVERLAY_ACTION)
        self.run_setup('--apply')
        self.assertIn('actions: 2', self.run_setup('--check').stdout)

    def test_overlay_error_mentioning_module_not_found_still_fails(self):
        for text in ('error("module dotfiles_private not found")\n',
                     "error(\"module 'dotfiles_private' not found\")\n"):
            with self.subTest(text=text):
                shutil.rmtree(Path(self.tmp.name)/'private', ignore_errors=True)
                self.make_overlay({'dotfiles_private.lua': text})
                self.run_setup('--apply', expected=1)
                self.assertFalse(self.config.exists())

    def test_overlay_package_directory_form_is_loaded(self):
        self.make_overlay({'dotfiles_private/init.lua': self.OVERLAY_ACTION})
        self.run_setup('--apply')
        self.assertIn('actions: 2', self.run_setup('--check').stdout)

    def test_overlay_loads_beside_a_custom_rex_config(self):
        custom = self.home/'custom/rex/main.lua'
        self.env['REX_CONFIG'] = str(custom)
        self.make_overlay({'dotfiles_private.lua': self.OVERLAY_ACTION})
        self.run_setup('--apply')
        self.assertTrue((custom.parent/'dotfiles_private.lua').is_file())
        self.assertTrue((custom.parent/'rex-image-paste/init.lua').is_file())
        self.assertIn('actions: 2', self.run_setup('--check').stdout)
        self.assertFalse(self.config.exists())

    def test_overlay_dir_trailing_slash_is_normalized(self):
        overlay = self.make_overlay({'dotfiles_private.lua': self.OVERLAY_ACTION})
        self.env['DOTFILES_REX_OVERLAY_DIR'] = str(overlay) + '//'
        self.run_setup('--apply')
        self.assertTrue((self.config/'dotfiles_private.lua').is_file())

    def test_overlay_must_not_ship_the_machine_local_allowlist(self):
        self.config.mkdir(parents=True)
        allowlist = self.config/'transfer-targets.json'
        allowlist.write_text('{"local": {}}\n')
        for name in ('transfer-targets.json', 'Transfer-Targets.JSON'):
            with self.subTest(name=name):
                shutil.rmtree(Path(self.tmp.name)/'private', ignore_errors=True)
                self.make_overlay({'dotfiles_private.lua': self.OVERLAY_ACTION, name: '{}\n'})
                result = self.run_setup('--apply', '--force', expected=1)
                self.assertIn('machine-local', result.stderr)
                self.assertEqual(allowlist.read_text(), '{"local": {}}\n')
                self.assertEqual(sorted(p.name for p in self.config.iterdir()), ['transfer-targets.json'])
        # A valid overlay leaves the existing machine-local allowlist alone.
        shutil.rmtree(Path(self.tmp.name)/'private')
        self.make_overlay({'dotfiles_private.lua': self.OVERLAY_ACTION})
        self.run_setup('--apply')
        self.assertEqual(allowlist.read_text(), '{"local": {}}\n')

    def test_destination_map_collisions_are_refused(self):
        cases = (
            # Custom config basename equal to an overlay file: same destination twice.
            ('dotfiles_private.lua', {'dotfiles_private.lua': self.OVERLAY_ACTION}),
            # Case-folded collisions (the Mac filesystem is case-insensitive).
            (None, {'INIT.LUA': '-- hijack\n'}),
            ('Main.lua', {'main.LUA': '-- hijack\n'}),
            (None, {'Rex-Image-Paste/x.lua': '-- hijack\n'}),
            (None, {'REX-IMAGE-PASTE': '-- file where a directory goes\n'}),
            # File/directory conflict inside the destination map.
            ('probe.lua', {'probe.lua/x.lua': '--\n'}),
        )
        for config_name, files in cases:
            with self.subTest(config=config_name, files=list(files)):
                shutil.rmtree(Path(self.tmp.name)/'private', ignore_errors=True)
                if config_name:
                    self.env['REX_CONFIG'] = str(self.config/config_name)
                else:
                    self.env.pop('REX_CONFIG', None)
                self.make_overlay(files)
                for mode in ((), ('--apply', '--force')):
                    self.run_setup(*mode, expected=1)
                    self.assertFalse(self.config.exists())

    def test_existing_file_where_overlay_needs_a_directory_is_refused(self):
        self.make_overlay({'probe_pkg/init.lua': self.OVERLAY_ACTION})
        self.config.mkdir(parents=True)
        (self.config/'probe_pkg').write_text('-- a file, not a directory\n')
        before = self.snapshot()
        result = self.run_setup('--apply', '--force', expected=1)
        self.assertIn('Not a directory', result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_replacement_is_atomic_and_does_not_write_through_hardlinks(self):
        self.config.mkdir(parents=True)
        outside = self.home/'outside.lua'
        outside.write_text('-- shared content\n')
        os.link(outside, self.config/'init.lua')
        self.run_setup('--apply', '--force')
        self.assertEqual(outside.read_text(), '-- shared content\n')
        self.assertEqual((self.config/'init.lua').read_bytes(), (ROOT/'config/rex/init.lua').read_bytes())
        backups = list((self.home/'.local/state/dotfiles/rex-backups').glob('apply-*/init.lua'))
        self.assertEqual([b.read_text() for b in backups], ['-- shared content\n'])
        self.assertEqual([p.name for p in self.config.rglob('.rex-config.*')], [])
        self.run_setup('--check')

    def test_overlay_cannot_replace_public_config_or_use_unsafe_paths(self):
        for files in ({'init.lua': '-- hijack\n'},
                      {'rex-image-paste/init.lua': '-- hijack\n'},
                      {'bad name.lua': '--\n'}):
            with self.subTest(files=list(files)):
                shutil.rmtree(Path(self.tmp.name)/'private', ignore_errors=True)
                self.make_overlay(files)
                self.run_setup('--apply', expected=1)
                self.assertFalse(self.config.exists())

    def test_overlay_symlinks_are_refused(self):
        overlay = self.make_overlay({'dotfiles_private.lua': self.OVERLAY_ACTION})
        (overlay/'linked.lua').symlink_to(overlay/'dotfiles_private.lua')
        self.run_setup('--apply', expected=1)
        self.assertFalse(self.config.exists())

    def test_overlay_file_conflicts_follow_force_and_backup_rules(self):
        self.make_overlay({'dotfiles_private.lua': self.OVERLAY_ACTION})
        self.config.mkdir(parents=True)
        (self.config/'dotfiles_private.lua').write_text('-- mine\n')
        self.run_setup('--apply', expected=1)
        self.assertEqual((self.config/'dotfiles_private.lua').read_text(), '-- mine\n')
        self.run_setup('--apply', '--force')
        backups = list((self.home/'.local/state/dotfiles/rex-backups').glob('apply-*/dotfiles_private.lua'))
        self.assertEqual([b.read_text() for b in backups], ['-- mine\n'])


    def test_custom_config_name_cannot_overwrite_the_transfer_allowlist(self):
        self.config.mkdir(parents=True)
        allowlist = self.config/'transfer-targets.json'
        allowlist.write_text('{"Steve": {"ssh": "remote"}}\n')
        for name in ('transfer-targets.json', 'Transfer-Targets.JSON'):
            with self.subTest(name=name):
                self.env['REX_CONFIG'] = str(self.config/name)
                self.run_setup(expected=1)
                self.run_setup('--apply', '--force', expected=1)
                self.assertEqual(allowlist.read_text(), '{"Steve": {"ssh": "remote"}}\n')
        self.env.pop('REX_CONFIG')

if __name__ == '__main__':
    unittest.main()
