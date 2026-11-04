#!/usr/bin/env node
// Local integration regression for Pi's native-compaction extension. No real
// credentials, MCP connections, or provider requests; capture the final payload
// through Pi's extension seam and stop before its transport sends anything.
// Optional: PI_COMPACTION_EXTENSION=/path/to/index.ts to check another release.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const executable = realpathSync(execFileSync('which', ['pi'], { encoding: 'utf8' }).trim());
let root = dirname(dirname(executable));
if (root.endsWith('/dist')) root = dirname(root); // Bundled npm executable.
const moduleAt = path => pathToFileURL(join(root, path)).href;
const { createJiti } = await import(moduleAt('node_modules/jiti/lib/jiti.mjs'));
const { createAgentSession, createCodemodeExtension, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager } = await import(moduleAt('dist/index.js'));
const jiti = createJiti(import.meta.url, { alias: {
  '@earendil-works/pi-coding-agent': join(root, 'dist/index.js'),
  '@earendil-works/pi-ai': join(root, 'node_modules/@earendil-works/pi-ai/dist/index.js'),
  '@earendil-works/pi-tui': join(root, 'node_modules/@earendil-works/pi-tui/dist/index.js'),
}});
const agentDir = process.env.PI_CODING_AGENT_DIR ?? join(process.env.HOME, '.pi/agent');
const extensionPath = process.env.PI_COMPACTION_EXTENSION ?? join(agentDir, 'npm/node_modules/@ogulcancelik/pi-codex-compaction/index.ts');
const extension = await jiti.import(extensionPath, { default: true });
const cwd = mkdtempSync(join(tmpdir(), 'pi-compaction-tools-'));
const stop = 'TEST_STOP_BEFORE_NETWORK';

try {
  const runtime = await ModelRuntime.create({ authPath: join(cwd, 'auth.json'), modelsPath: null, modelsStorePath: join(cwd, 'models-store.json'), refreshOnCreate: false });
  // Fabricated token and loopback endpoint: no real auth files are opened, and a
  // broken capture hook cannot accidentally send a request to an external host.
  const token = 'test.' + Buffer.from(JSON.stringify({ 'https://api.openai.com/auth': { chatgpt_account_id: 'test-account' } })).toString('base64url') + '.test';
  runtime.registerProvider('openai-codex', { apiKey: token, baseUrl: 'http://127.0.0.1:9' });
  const model = runtime.getModel('openai-codex', 'gpt-6.1-sol');
  assert.ok(model, 'This check requires the reviewed Codex model in the installed Pi catalog.');
  const manager = SessionManager.inMemory(cwd);
  manager.appendMessage({ role: 'user', content: [{ type: 'text', text: 'Synthetic history before compaction.' }], timestamp: 1 });
  manager.appendCustomEntry('openai-codex-native-compaction', {
    kind: 'openai-codex-native-compaction', version: 1,
    modelKey: `${model.provider}:${model.api}:${model.id}`,
    replacementHistory: [{ type: 'compaction', encrypted_content: 'synthetic-checkpoint' }],
  });
  const entries = manager.getEntries();
  const modernManager = SessionManager.inMemory(cwd);
  const firstKept = modernManager.appendMessage({ role: 'user', content: [{ type: 'text', text: 'Synthetic retained history.' }], timestamp: 1 });
  modernManager.appendCompaction('OpenAI Codex native compaction checkpoint (synthetic).', firstKept, 450000, entries.at(-1).data, true);
  const modernEntries = modernManager.getEntries();

  // Fresh sessions cover both old custom-entry recovery and current Pi-owned
  // compaction entries, with and without a hot reload before the next request.
  for (let pass = 0; pass < 4; pass++) {
    const format = pass < 2 ? 'legacy checkpoint' : 'Pi compaction entry';
    let captured;
    const settingsManager = SettingsManager.inMemory({ packages: [], compaction: { enabled: false }, retry: { enabled: false }, defaultTools: ['read', 'bash', 'codemode'] });
    const resourceLoader = new DefaultResourceLoader({ cwd, agentDir: cwd, settingsManager,
      noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true,
      agentsFilesOverride: () => ({ agentsFiles: [] }),
      extensionFactories: [createCodemodeExtension({ mode: 'on' }), extension, pi => {
        pi.on('before_provider_request', (event, ctx) => {
          captured = structuredClone(event.payload);
          ctx.abort();
          throw new Error(stop);
        });
      }],
    });
    await resourceLoader.reload();
    assert.deepEqual(resourceLoader.getExtensions().errors, []);
    const { session } = await createAgentSession({ cwd, agentDir: cwd, modelRuntime: runtime, model, resourceLoader, settingsManager,
      sessionManager: SessionManager.inMemory(cwd, undefined, pass < 2 ? entries : modernEntries) });
    try {
      await session.bindExtensions({});
      if (pass % 2 === 1) await session.reload();
      await session.prompt('Read-only maintenance check. Do not run project work.');
      assert.ok(captured, 'Final provider payload must reach the capture hook.');
      assert.equal(session.messages.at(-1)?.stopReason, 'aborted', 'Capture must abort the provider request.');
      const tools = [...(captured.tools ?? []), ...captured.input
        .filter(item => item.type === 'additional_tools' || item.type === 'tool_search_output')
        .flatMap(item => item.tools ?? [])];
      const names = new Set(tools.map(tool => tool.name));
      for (const name of ['read', 'bash', 'codemode']) assert.ok(names.has(name), `Missing tool after checkpoint replay: ${name}`);
      assert.equal(tools.find(tool => tool.name === 'codemode').type, 'custom', 'Codemode grammar input must not become a JSON function.');
      assert.equal(captured.input.filter(item => item.type === 'compaction').length, 1);
      assert.ok(!JSON.stringify(captured.input).includes('OpenAI Codex native compaction history ('), 'Local checkpoint placeholder must not leak.');
      console.log(`PASS: ${format}, ${pass % 2 === 0 ? 'resume' : 'reload'} retains read, bash, grammar codemode, and exactly one checkpoint.`);
    } finally { session.dispose(); }
  }
} finally { rmSync(cwd, { recursive: true, force: true }); }
