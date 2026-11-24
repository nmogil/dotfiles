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
        self.env.pop('REX_CONFIG', None)

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
        (fixture/'scripts').mkdir(parents=True)
        shutil.copytree(ROOT/'config/rex', fixture/'config/rex')
        shutil.copy2(ROOT/'scripts/setup-rex-config.sh', fixture/'scripts/setup-rex-config.sh')
        (fixture/'config/rex/rex-image-paste/init.lua').write_text('error("must not execute")\n')
        self.run_setup('--apply', script=fixture/'scripts/setup-rex-config.sh', expected=1)
        self.assertFalse(self.config.exists())


if __name__ == '__main__':
    unittest.main()
