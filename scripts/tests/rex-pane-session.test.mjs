#!/usr/bin/env node
// rex-pane-session Pi extension: drives its registered handlers the way Pi
// does, against real files in a temporary HOME. No Pi runtime or network.
import assert from 'node:assert/strict';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// The recorder identifies its process by /proc start time (Linux only).
if (!existsSync('/proc/self/stat')) {
  console.log('SKIP rex-pane-session: needs Linux /proc (the recorder reads /proc/self/stat); not available on this OS');
  process.exit(0);
}

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const work = mkdtempSync(join(tmpdir(), 'rex-pane-session-'));
const block = 'block:00000000-0000-0000-0000-0000000000aa';
const record = join(work, '.local/state/rex-safe-upgrade/panes', `${block.slice(6)}.json`);

// The extension reads HOME and REX_BLOCK when it loads.
async function load(name, env) {
  Object.assign(process.env, { HOME: work }, env);
  const copy = join(work, `${name}.mjs`); // plain JS apart from the .ts name
  copyFileSync(join(root, 'templates/pi-rex/rex-pane-session.ts'), copy);
  const handlers = {};
  (await import(pathToFileURL(copy).href)).default({ on: (event, fn) => { handlers[event] = fn; } });
  return handlers;
}

const notes = [];
const ctx = (file, entries = []) => ({
  cwd: '/work',
  sessionManager: { getSessionFile: () => file, getSessionId: () => `id-${file}`, getEntries: () => entries },
  ui: { notify: (msg, level) => notes.push({ msg, level }) },
});
const read = () => JSON.parse(readFileSync(record, 'utf8'));
const ownStartTicks = readFileSync('/proc/self/stat', 'utf8').split(')').pop().trim().split(' ')[19];

try {
  delete process.env.REX_BLOCK;
  assert.deepEqual(await load('outside', {}), {}, 'does nothing outside Rex');

  const on = await load('inside', { REX_BLOCK: block, REX_SESSION: 'session:x' });

  await on.session_start({ reason: 'startup' }, ctx('/s/a.jsonl'));
  let r = read();
  assert.equal(r.v, 2);
  assert.equal(r.pid, process.pid);
  assert.equal(r.startTicks, ownStartTicks);
  assert.equal(r.sessionFile, '/s/a.jsonl');
  assert.equal(r.hasMessages, false);

  await on.agent_end({}, ctx('/s/a.jsonl'));
  assert.equal(read().hasMessages, true);

  // A resumed session that already has user messages.
  await on.session_start({ reason: 'resume' }, ctx('/s/a.jsonl', [{ type: 'message', message: { role: 'user' } }]));
  assert.equal(read().hasMessages, true);

  // Switching drops the record before Pi changes session...
  assert.equal(await on.session_before_switch({ reason: 'new' }, ctx('/s/a.jsonl')), undefined);
  assert.equal(existsSync(record), false);
  // ...and the next session writes its own.
  await on.session_start({ reason: 'new' }, ctx('/s/b.jsonl', [{ type: 'message', message: { role: 'system' } }]));
  assert.equal(read().sessionFile, '/s/b.jsonl');
  assert.equal(read().hasMessages, false, 'system messages are not conversation');

  // If the record can't be dropped (here: the path is a non-empty directory,
  // which also makes the next write fail), switching and forking are cancelled.
  rmSync(record);
  mkdirSync(join(record, 'stuck'), { recursive: true });
  assert.deepEqual(await on.session_before_switch({ reason: 'resume' }, ctx('/s/b.jsonl')), { cancel: true });
  assert.deepEqual(await on.session_before_fork({}, ctx('/s/b.jsonl')), { cancel: true });
  assert.equal(notes.length, 2);
  assert.equal(notes[0].level, 'error');
  assert.match(notes[0].msg, /session switch cancelled/);
  await on.session_start({ reason: 'new' }, ctx('/s/c.jsonl')); // write fails quietly
  rmSync(record, { recursive: true });

  // Rex preview.23 sets only REX_BLOCK: the record is still written, with no session.
  delete process.env.REX_SESSION;
  await on.session_start({ reason: 'new' }, ctx('/s/d.jsonl'));
  assert.equal(read().sessionFile, '/s/d.jsonl');
  assert.equal(read().session, null);
  rmSync(record);

  // Quit removes the record.
  writeFileSync(record, '{}');
  await on.session_shutdown({ reason: 'quit' }, ctx('/s/b.jsonl'));
  assert.equal(existsSync(record), false);

  console.log('rex-pane-session: ok');
} finally {
  rmSync(work, { recursive: true, force: true });
}
