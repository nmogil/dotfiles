#!/usr/bin/env python3
"""Real Git integration tests; no GitHub/Vercel writes or live HOME access."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/git-identity-guard.py'
GOOD = 'owner@example.test'
BAD = 'other@example.test'


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('GIT_', 'XDG_'))}
        self.env.update(HOME=str(self.home), GIT_CONFIG_NOSYSTEM='1',
                        GIT_TERMINAL_PROMPT='0')
        self.repo = self.home / 'repo'
        self.repo.mkdir()
        self.cmd('git', 'init', '-q', '-b', 'main')
        self.cmd('git', 'config', '--global', 'user.name', 'Wrong Global')
        self.cmd('git', 'config', '--global', 'user.email', BAD)
        self.cmd('git', 'remote', 'add', 'origin', 'https://github.com/example/project.git')
        self.policy = self.home / 'policy.json'
        self.policy.write_text(json.dumps({'rules': [{
            'id': 'example', 'name': 'Correct Owner', 'email': GOOD,
            'patterns': ['https://github.com/example/*', 'git@github.com:example/*',
                         'ssh://git@github.com/example/*']}]}))
        self.install()

    def cmd(self, *args, ok=True, env=None, cwd=None, input=None):
        result = subprocess.run(args, cwd=cwd or self.repo,
                                env=self.env | (env or {}), input=input,
                                capture_output=True, text=True)
        if ok and result.returncode:
            self.fail(f'{args}: {result.returncode}\n{result.stdout}\n{result.stderr}')
        return result

    def install(self):
        return self.cmd(sys.executable, str(SCRIPT), 'install', str(self.policy))

    def commit(self, *args, env=None, ok=True):
        return self.cmd('git', 'commit', '--allow-empty', '-qm', 'test', *args,
                        env=env, ok=ok)

    def test_remote_identity_and_commit(self):
        self.assertEqual(self.cmd('git', 'config', 'user.email').stdout.strip(), GOOD)
        self.commit()
        self.assertEqual(self.cmd('git', 'show', '-s', '--format=%ae').stdout.strip(), GOOD)

    def test_local_override_is_blocked(self):
        self.cmd('git', 'config', '--local', 'user.email', BAD)
        self.assertIn('BLOCKED', self.commit(ok=False).stderr)

    def test_environment_author_is_blocked(self):
        self.assertIn('BLOCKED', self.commit(env={'GIT_AUTHOR_EMAIL': BAD}, ok=False).stderr)

    def test_environment_committer_is_blocked(self):
        self.assertIn('BLOCKED', self.commit(env={'GIT_COMMITTER_EMAIL': BAD}, ok=False).stderr)

    def test_author_flag_is_blocked(self):
        self.assertIn('BLOCKED', self.commit('--author', f'Other <{BAD}>', ok=False).stderr)

    def test_command_config_override_is_blocked(self):
        result = self.cmd('git', '-c', f'user.email={BAD}', 'commit', '--allow-empty',
                          '-qm', 'test', ok=False)
        self.assertIn('BLOCKED', result.stderr)

    def test_unrelated_repo_unchanged(self):
        self.cmd('git', 'remote', 'set-url', 'origin', 'https://github.com/unrelated/project.git')
        self.assertEqual(self.cmd('git', 'config', 'user.email').stdout.strip(), BAD)
        self.commit()

    def test_ssh_and_linked_worktree(self):
        self.cmd('git', 'remote', 'set-url', 'origin', 'git@github.com:example/project.git')
        self.commit()
        wt = self.home / 'elsewhere'
        self.cmd('git', 'worktree', 'add', '-qb', 'feature', str(wt))
        self.assertEqual(self.cmd('git', 'config', 'user.email', cwd=wt).stdout.strip(), GOOD)
        self.cmd('git', 'commit', '--allow-empty', '-qm', 'worktree', cwd=wt)

    def test_existing_hook_runs_and_failure_is_preserved(self):
        hook = self.repo / '.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\necho ORIGINAL_HOOK >&2\nexit 23\n')
        hook.chmod(0o755)
        result = self.commit(ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ORIGINAL_HOOK', result.stderr)

    def test_idempotent_install(self):
        before = (self.home / '.gitconfig').read_bytes()
        self.install()
        self.assertEqual(before, (self.home / '.gitconfig').read_bytes())
        self.commit()

    def test_local_hooks_override_detected_by_preflight(self):
        self.cmd('git', 'config', 'core.hooksPath', '/dev/null')
        result = self.cmd(sys.executable, str(SCRIPT), 'check', ok=False)
        self.assertIn('hooksPath', result.stderr)

    def test_actual_local_push_blocks_bad_tip(self):
        self.commit()
        sink = self.home / 'sink.git'
        self.cmd('git', 'init', '--bare', '-q', str(sink))
        self.cmd('git', 'remote', 'add', 'sink', str(sink))
        self.cmd('git', 'push', '-q', 'sink', 'HEAD:refs/heads/good')
        # Construct a historical bad tip without bypassing the commit hook.
        tree = self.cmd('git', 'rev-parse', 'HEAD^{tree}').stdout.strip()
        sha = self.cmd('git', 'commit-tree', tree, '-m', 'bad historical tip',
                       env={'GIT_AUTHOR_EMAIL': BAD}).stdout.strip()
        self.cmd('git', 'branch', 'bad', sha)
        result = self.cmd('git', 'push', 'sink', 'bad:refs/heads/bad', ok=False)
        self.assertIn('BLOCKED', result.stderr)
        self.assertEqual(self.cmd('git', '--git-dir', str(sink), 'show-ref',
                                 'refs/heads/bad', ok=False).returncode, 1)

    def test_preserves_pre_push_stdin_and_arguments(self):
        self.commit()
        hook = self.repo / '.git/hooks/pre-push'
        hook.write_text('#!/bin/sh\nprintf "ORIGINAL_ARGS:%s:%s\\n" "$1" "$2" >&2\nwhile read -r line; do printf "ORIGINAL_LINE:%s\\n" "$line" >&2; done\nexit 17\n')
        hook.chmod(0o755)
        sha = self.cmd('git', 'rev-parse', 'HEAD').stdout.strip()
        line = f'refs/heads/main {sha} refs/heads/main {"0" * 40}\n'
        result = self.cmd(str(self.home / '.local/share/git-identity-guard/hooks/pre-push'),
                          'origin', 'https://github.com/example/project.git',
                          input=line, ok=False)
        self.assertEqual(result.returncode, 17)
        self.assertIn('ORIGINAL_ARGS:origin:https://github.com/example/project.git', result.stderr)
        self.assertIn('ORIGINAL_LINE:' + line.strip(), result.stderr)

    def test_global_hook_manager_refused_without_mutation(self):
        self.cmd('git', 'config', '--global', 'core.hooksPath', '/custom/hooks')
        before = (self.home / '.gitconfig').read_bytes()
        result = self.cmd(sys.executable, str(SCRIPT), 'install', str(self.policy), ok=False)
        self.assertIn('existing global core.hooksPath', result.stderr)
        self.assertEqual(before, (self.home / '.gitconfig').read_bytes())

    def test_pi_handler_with_real_guard(self):
        extension = ROOT / 'templates/pi-identity/git-identity-preflight.ts'
        code = '''
import { pathToFileURL } from 'node:url';
const {default: extension} = await import(pathToFileURL(process.argv[1]).href);
let handler;
let command;
extension({on: (name, fn) => { if (name === 'tool_call') handler = fn; },
           registerCommand: (name, spec) => { command = name; }});
const result = handler({toolName: 'bash', input: {command: 'git commit -m test'}}, {cwd: process.cwd()});
console.log(JSON.stringify({command, blocked: result?.block === true}));
'''
        result = self.cmd('node', '--experimental-strip-types', '--input-type=module',
                          '-e', code, str(extension))
        self.assertEqual(json.loads(result.stdout), {'command': 'git-identity', 'blocked': False})
        self.cmd('git', 'config', 'user.email', BAD)
        result = self.cmd('node', '--experimental-strip-types', '--input-type=module',
                          '-e', code, str(extension))
        self.assertEqual(json.loads(result.stdout), {'command': 'git-identity', 'blocked': True})

    def test_included_global_hooks_refused(self):
        # An existing include, not a directly declared global hooksPath.
        manager = self.home / 'manager.gitconfig'
        manager.write_text('[core]\n    hooksPath = /custom/included/hooks\n')
        self.cmd('git', 'config', '--global', '--add', 'include.path', str(manager))
        before = (self.home / '.gitconfig').read_bytes()
        result = self.cmd(sys.executable, str(SCRIPT), 'install', str(self.policy), ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('hook', result.stderr.lower())
        self.assertEqual(before, (self.home / '.gitconfig').read_bytes())

    def test_receive_hook_rejection_is_preserved(self):
        self.commit()
        sink = self.home / 'receive.git'
        self.cmd('git', 'init', '--bare', '-q', str(sink))
        self.cmd('git', '--git-dir', str(sink), 'config', 'remote.origin.url',
                 'https://github.com/example/project.git')
        hook = sink / 'hooks/update'
        hook.write_text('#!/bin/sh\necho RECEIVE_REJECT >&2\nexit 1\n')
        hook.chmod(0o755)
        result = self.cmd('git', 'push', str(sink), 'HEAD:refs/heads/main', ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('RECEIVE_REJECT', result.stderr)

    def test_xdg_global_config_in_backup(self):
        xdg = self.home / 'alternate-config'
        config = xdg / 'git/config'
        config.parent.mkdir(parents=True)
        (self.home / '.gitconfig').unlink()
        config.write_text('[user]\n    name = Original\n    email = original@example.test\n')
        before = config.read_bytes()
        self.env['XDG_CONFIG_HOME'] = str(xdg)
        result = self.install()
        backup = Path(result.stdout.split('Rollback snapshot: ')[1].strip())
        self.assertNotEqual(before, config.read_bytes())
        manifest = json.loads((backup / 'manifest.json').read_text())
        entry = next(item for item in manifest if item['path'] == str(config))
        self.assertTrue(entry['existed'])
        self.assertEqual(before, (backup / entry['snapshot']).read_bytes())

    def test_preflight_outside_repo_is_noop(self):
        self.cmd(sys.executable, str(SCRIPT), 'check', cwd=self.home)


if __name__ == '__main__':
    unittest.main()
