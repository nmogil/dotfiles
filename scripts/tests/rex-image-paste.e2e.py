#!/usr/bin/env python3
"""Run pinned upstream image-paste tests in disposable Rex sessions.

Uses a synthetic PNG and a private named pasteboard, never the real clipboard.
No agent is started and no prompt is sent. --host takes a saved Rex host label.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import uuid
import zlib

ROOT = Path(__file__).resolve().parents[2]


def png(path, width, height):
    def chunk(name, data):
        return struct.pack('!I', len(data)) + name + data + struct.pack('!I', zlib.crc32(name + data) & 0xffffffff)
    rows = b''.join(b'\0' + os.urandom(width * 3) for _ in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', width, height, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', help='saved Rex host label for additional remote tests')
    args = parser.parse_args()
    rex = os.environ.get('REX_BIN') or shutil.which('rex') or str(
        Path.home()/'Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex')
    module = ROOT/'config/rex/rex-image-paste'
    # Validate immutable upstream source before running its test code.
    subprocess.run(['shasum', '-a', '256', '--check', 'checksums.sha256'], cwd=module, check=True)
    sessions = []
    with tempfile.TemporaryDirectory(prefix='rex-image-paste-e2e-') as directory:
        tmp = Path(directory)
        fixture = tmp/'synthetic.png'
        large = tmp/'large-synthetic.png'
        png(fixture, 256, 256)  # Several upload chunks; not personal image data.
        png(large, 2400, 40)   # Exercise the default 2000-pixel resize.
        source = (module/'test/e2e.lua').read_text()
        # Keep upstream intact. Only isolate its module, target session, and
        # named test pasteboard so it never touches an existing user's pane.
        roots = [line for line in source.splitlines() if line.startswith('local root = ')]
        assert len(roots) == 1, 'Upstream test entry point changed'
        first = roots[0]
        source = source.replace(first, 'local root = assert(rex.args.module)', 1)
        original = 'session_id = assert(sessions[1], "no sessions on " .. host).session_id'
        assert source.count(original) == 1
        source = source.replace(original, 'session_id = assert(rex.args.remote_session)', 1)
        source = source.replace('M.options.pasteboard = "rex-image-paste-test"',
                                'M.options.pasteboard = assert(rex.args.pasteboard)', 1)
        script = tmp/'isolated-e2e.lua'
        script.write_text(source)
        pasteboard = 'dotfiles-rex-image-paste-' + str(uuid.uuid4())

        def create(prefix):
            result = json.loads(subprocess.check_output(prefix + [
                'new', 'rex-image-paste-test', '--shell', 'none', '--json', '--', '/usr/bin/tail', '-f', '/dev/null'], text=True))
            sessions.append((prefix, result['session_id']))
            return result['session_id']

        try:
            local = create([rex])
            remote = create([rex, '-S', args.host]) if args.host else None
            for host in [None] + ([args.host] if args.host else []):
                for kind in ('png', 'tiff', 'file', 'text', 'large'):
                    cmd = [rex, '--timeout', '90s', 'do', '-s', local, str(script),
                           'module=' + str(module), 'pasteboard=' + pasteboard,
                           'kind=' + ('png' if kind == 'large' else kind),
                           'src=' + str(large if kind == 'large' else fixture)]
                    if host:
                        cmd += ['host=' + host, 'remote_session=' + remote]
                    print('\n=== ' + ('remote' if host else 'local') + ' / ' + kind + ' ===', flush=True)
                    subprocess.run(cmd, check=True, timeout=95)
        finally:
            for prefix, session in reversed(sessions):
                subprocess.run(prefix + ['kill', session], check=True)
    print('\nImage-paste e2e passed; disposable Rex sessions removed.')


if __name__ == '__main__':
    main()
