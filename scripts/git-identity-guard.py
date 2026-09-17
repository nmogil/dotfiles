#!/usr/bin/env python3
"""Opt-in, remote-scoped Git identity guard. Requires Git >= 2.36, Python >= 3.9."""
import fnmatch
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

HOME = Path.home()
BASE = HOME / '.local/share/git-identity-guard'
POLICY = HOME / '.config/git/identity-guard.json'
INCLUDE = HOME / '.config/git/identity-guard.gitconfig'
MARKER = '# Managed by git-identity-guard; do not edit.\n'
HOOKS = ('pre-commit', 'pre-push', 'prepare-commit-msg', 'commit-msg',
         'post-commit', 'pre-rebase', 'post-checkout', 'post-merge',
         'pre-merge-commit', 'post-rewrite', 'applypatch-msg',
         'pre-applypatch', 'post-applypatch', 'post-index-change',
         'reference-transaction', 'push-to-checkout', 'pre-auto-gc',
         'sendemail-validate', 'fsmonitor-watchman', 'p4-changelist',
         'p4-prepare-changelist', 'p4-post-changelist', 'p4-pre-submit',
         'pre-receive', 'update', 'post-receive', 'post-update', 'proc-receive')


def git(*args, optional=False):
    result = subprocess.run(['git', *args], capture_output=True, text=True)
    if result.returncode and not optional:
        raise ValueError(f'git {args[0]} failed: {result.stderr.strip()}')
    return result.stdout.strip()


def load_policy(path=POLICY):
    data = json.loads(path.read_text())
    rules = data['rules']
    if not isinstance(rules, list) or not rules:
        raise ValueError('policy needs a nonempty rules list')
    ids = set()
    for rule in rules:
        if not re.fullmatch(r'[a-z0-9-]+', rule['id']) or rule['id'] in ids:
            raise ValueError('rule ids must be unique lowercase slugs')
        ids.add(rule['id'])
        for key in ('name', 'email'):
            if not isinstance(rule[key], str) or not rule[key] or any(
                    ord(c) < 32 or c in '<>' for c in rule[key]):
                raise ValueError(f'invalid {key}')
        if not re.fullmatch(r'[^\s@]+@[^\s@]+', rule['email']):
            raise ValueError('invalid email')
        if not isinstance(rule['patterns'], list) or not rule['patterns']:
            raise ValueError('patterns must be a nonempty list')
        for pattern in rule['patterns']:
            # Deliberately constrain to one trailing wildcard: Git wildmatch
            # and Python fnmatch then agree for our remote-prefix use case.
            if not isinstance(pattern, str) or not pattern.endswith('/*') or any(
                    c in pattern[:-1] for c in '*?[]\\\n\r\t"'):
                raise ValueError('patterns must be remote prefixes ending /*')
    return data


def active_rule():
    if not git('rev-parse', '--git-dir', optional=True):
        return None
    if not POLICY.exists():
        raise ValueError(f'missing policy {POLICY}')
    urls = git('config', '--get-regexp', r'^remote\..*\.url$', optional=True)
    urls = [line.split(' ', 1)[1] for line in urls.splitlines()]
    matches = [r for r in load_policy()['rules'] if any(
        fnmatch.fnmatchcase(url, p) for url in urls for p in r['patterns'])]
    if len(matches) > 1:
        raise ValueError('remotes match multiple identity rules; resolve explicitly')
    return matches[0] if matches else None


def check(rule):
    if not rule:
        return
    expected = rule['email']
    for variable in ('GIT_AUTHOR_IDENT', 'GIT_COMMITTER_IDENT'):
        value = git('var', variable)
        match = re.search(r'<([^<>]+)>', value)
        if not match or match.group(1) != expected:
            raise ValueError(f'{rule["id"]}: {variable} must use {expected}; '
                             'fix repo config / author override; do not bypass hooks')
    paths = git('config', '--includes', '--path', '--get-all',
                'core.hooksPath', optional=True).splitlines()
    if not paths or any(Path(p).resolve() != (BASE / 'hooks').resolve() for p in paths):
        raise ValueError('core.hooksPath overrides the identity guard; '
                         'integrate the existing hook manager explicitly')


def hook(name, args):
    data = sys.stdin.buffer.read() if name == 'pre-push' else None
    if name in ('pre-commit', 'pre-push', 'pre-merge-commit'):
        rule = active_rule()
        check(rule)
        if name == 'pre-push' and rule:
            for line in (data or b'').decode().splitlines():
                local_ref, sha, remote_ref, remote_sha = line.split()
                if set(sha) == {'0'}:
                    continue  # deletion, not a deployment-triggering commit
                commit = git('rev-parse', '--verify', f'{sha}^{{commit}}', optional=True)
                if not commit:
                    raise ValueError('cannot verify pushed object as a commit')
                author = git('show', '-s', '--format=%ae', commit)
                if author != rule['email']:
                    raise ValueError(f'pushed tip {commit[:12]} author is not '
                                     f'{rule["email"]}; stop and review attribution')
    # Preserve normal repo-local hooks, including linked-worktree common hooks.
    common = Path(git('rev-parse', '--git-common-dir')).resolve()
    original = common / 'hooks' / name
    if original.is_file() and os.access(original, os.X_OK):
        result = subprocess.run([str(original), *args], input=data)
        return result.returncode
    return 0


def install(source):
    data = load_policy(Path(source))
    match = re.search(r'(\d+)\.(\d+)', git('--version'))
    if not match:
        raise ValueError('cannot determine Git version')
    version = tuple(map(int, match.groups()))
    if version < (2, 36):
        raise ValueError('Git >= 2.36 is required for remote-based includeIf')
    if any(os.environ.get(k) for k in ('GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM',
                                       'GIT_CONFIG_COUNT')):
        raise ValueError('install requires standard Git config paths (clear overrides)')
    # Include expansion is opt-in when --global/--system is specified. Check
    # every applicable value, not just the winning value, before replacing it.
    hook_values = []
    for scope in (('--global',), ('--system',), ()):
        hook_values.extend(git('config', *scope, '--includes', '--get-all',
                               'core.hooksPath', optional=True).splitlines())
    if any(Path(p).expanduser().resolve() != (BASE / 'hooks').resolve()
           for p in hook_values):
        raise ValueError('existing global core.hooksPath or scoped hook manager requires manual integration')
    if BASE.exists() and not (BASE / 'MANAGED').is_file():
        raise ValueError(f'refusing to overwrite unmanaged {BASE}')
    if INCLUDE.exists() and not INCLUDE.read_text().startswith(MARKER):
        raise ValueError(f'refusing to overwrite unmanaged {INCLUDE}')
    if POLICY.exists() and not BASE.exists():
        raise ValueError(f'existing policy {POLICY} requires review')
    # Stage generated files before changing live includes; private identities
    # stay outside the public source. Existing files get a rollback snapshot.
    with tempfile.TemporaryDirectory(prefix='identity-guard-stage-') as tmp:
        stage = Path(tmp)
        includes = MARKER
        for rule in data['rules']:
            config = stage / f'{rule["id"]}.gitconfig'
            for key, value in [('user.name', rule['name']), ('user.email', rule['email']),
                               ('user.useConfigOnly', 'true'),
                               ('core.hooksPath', str(BASE / 'hooks'))]:
                git('config', '--file', str(config), key, value)
            for pattern in rule['patterns']:
                includes += (f'[includeIf "hasconfig:remote.*.url:{pattern}"]\n'
                             f'    path = {json.dumps(str(BASE / config.name))}\n')
        xdg = Path(os.environ.get('XDG_CONFIG_HOME') or HOME / '.config')
        targets = (HOME / '.gitconfig', xdg / 'git/config', INCLUDE, POLICY)
        backup = Path(tempfile.mkdtemp(prefix='git-identity-backup-', dir=HOME))
        backup.chmod(0o700)
        manifest = []
        for index, p in enumerate(targets):
            snapshot = f'file-{index}'
            manifest.append({'path': str(p), 'existed': p.exists(), 'snapshot': snapshot})
            if p.exists():
                shutil.copy2(p, backup / snapshot)
        (backup / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        if BASE.exists():
            shutil.copytree(BASE, backup / 'runtime')
        BASE.mkdir(parents=True, exist_ok=True)
        BASE.chmod(0o700)
        (BASE / 'MANAGED').write_text(MARKER)
        (BASE / 'guard.py').write_bytes(Path(__file__).read_bytes())
        for config in stage.iterdir():
            shutil.copy2(config, BASE / config.name)
        hooks = BASE / 'hooks'
        hooks.mkdir(exist_ok=True)
        for name in HOOKS:
            target = hooks / name
            target.write_text('#!/bin/sh\n' + MARKER + 'exec python3 ' +
                              shlex.quote(str(BASE / 'guard.py')) + ' hook ' +
                              shlex.quote(name) + ' "$@"\n')
            target.chmod(0o755)
        POLICY.parent.mkdir(parents=True, exist_ok=True)
        POLICY.write_text(json.dumps(data, indent=2) + '\n')
        POLICY.chmod(0o600)
        INCLUDE.write_text(includes)
        INCLUDE.chmod(0o600)
        paths = git('config', '--global', '--get-all', 'include.path', optional=True).splitlines()
        if str(INCLUDE) not in paths:
            git('config', '--global', '--add', 'include.path', str(INCLUDE))
        print(f'Installed remote-scoped guard. Rollback snapshot: {backup}')


def main():
    if len(sys.argv) == 3 and sys.argv[1] == 'install':
        install(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == 'check':
        check(active_rule())
    elif len(sys.argv) >= 3 and sys.argv[1] == 'hook' and sys.argv[2] in HOOKS:
        return hook(sys.argv[2], sys.argv[3:])
    else:
        raise ValueError('usage: guard.py install POLICY.json | check | hook NAME [args]')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print(f'BLOCKED: git-identity-guard: {exc}', file=sys.stderr)
        sys.exit(1)
