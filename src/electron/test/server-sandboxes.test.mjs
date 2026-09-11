// test/server-sandboxes.test.mjs — the project's first HTTP-level test.
//
// Starts the real server with a fake `sbx` on PATH (test-fixtures/sbx-shim.js
// — deliberately NOT under test/, since `node --test`'s default discovery
// treats any file inside a directory literally named "test" as a test file
// to run — copied in as the exact name "sbx" since PATH lookup is by exact
// filename) and drives it with fetch. The shim logs the argv of EVERY call
// (reads included) to a file, so assertions here are on exactly what the
// server would spawn for real — not on a mock of the server's own code.
//
// SBX_HELPER_CONFIG must be set *before* server.mjs is imported (it reads
// the env var at module top level and, if the file is missing, WRITES
// defaults to it) — hence the dynamic import after env setup, done once for
// the whole file since startServer()'s module-level `server` isn't
// restartable across multiple startServer() calls in one process.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let baseUrl, token, stopServer, configPath;
let binDir, logPath;
let launcherCalls;

function readLog() {
  if (!fs.existsSync(logPath)) return [];
  return fs
    .readFileSync(logPath, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function resetLog() {
  fs.writeFileSync(logPath, '');
  launcherCalls.length = 0;
}

// Every request that acts on a sandbox re-validates its name against a
// fresh `sbx ls --json` first — that's a read, and it's expected to show up
// in the log even on a request that gets rejected. What actually matters
// for "rejected without doing anything" is that no *mutating* command ran.
function mutatingLoggedCommands() {
  return readLog().filter((entry) => {
    if (entry[0] === 'stop' || entry[0] === 'rm') return true;
    if (entry[0] === 'policy' && ['allow', 'deny', 'rm'].includes(entry[1])) return true;
    return false;
  });
}

function policyLsLoggedCommands() {
  return readLog().filter((entry) => entry[0] === 'policy' && entry[1] === 'ls');
}

function readConfig() {
  return JSON.parse(fs.readFileSync(configPath, 'utf8'));
}

async function apiFetch(pathAndQuery, options = {}) {
  const res = await fetch(`${baseUrl}${pathAndQuery}`, {
    ...options,
    headers: { 'content-type': 'application/json', 'x-sbx-helper-token': token, ...(options.headers || {}) },
  });
  const body = await res.json().catch(() => ({}));
  return { status: res.status, body };
}

before(async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sbx-helper-it-'));
  binDir = path.join(tmp, 'bin');
  fs.mkdirSync(binDir);
  fs.copyFileSync(path.join(__dirname, '..', 'test-fixtures', 'sbx-shim.js'), path.join(binDir, 'sbx'));
  fs.chmodSync(path.join(binDir, 'sbx'), 0o755);

  logPath = path.join(tmp, 'argv.log');
  fs.writeFileSync(logPath, '');
  launcherCalls = [];

  configPath = path.join(tmp, 'sbx-helper.json');
  process.env.SBX_SHIM_LOG = logPath;
  process.env.SBX_HELPER_CONFIG = configPath;
  process.env.PATH = `${binDir}${path.delimiter}${process.env.PATH}`;

  const { startServer, stopServer: stop } = await import('../server.mjs');
  stopServer = stop;
  // A recording launcher in place of launchInTerminal — the real one would
  // open an actual iTerm/Terminal window (and, if the test env's PATH ever
  // leaked through to it, could even run a REAL `sbx run`). Injecting it is
  // what makes /api/run and /api/sandbox/run testable at all.
  const started = await startServer({
    openBrowser: false,
    launcher: async (args) => {
      launcherCalls.push(args);
      return { ok: true, method: 'test-launcher' };
    },
  });
  baseUrl = `http://127.0.0.1:${started.port}`;
  token = started.token;
});

after(async () => {
  await stopServer();
});

test('GET /api/sandboxes returns the parsed sbx ls list', async () => {
  const { status, body } = await apiFetch('/api/sandboxes');
  assert.equal(status, 200);
  assert.equal(body.sandboxes.length, 2);
  const names = body.sandboxes.map((s) => s.name);
  assert.deepEqual(names.sort(), ['test-sandbox-1', 'test-sandbox-2']);
  const running = body.sandboxes.find((s) => s.name === 'test-sandbox-1');
  assert.equal(running.agent, 'claude');
  assert.equal(running.status, 'running');
});

test('GET / still serves the app after the static-path check tightened to require a trailing separator', async () => {
  const res = await fetch(`${baseUrl}/`);
  assert.equal(res.status, 200);
  const text = await res.text();
  assert.match(text, /<title>sbx-helper<\/title>/);
});

test('GET /api/sandbox-policies returns network rules classified for the named sandbox', async () => {
  const { status, body } = await apiFetch('/api/sandbox-policies?name=test-sandbox-1');
  assert.equal(status, 200);
  const removable = body.rules.find((r) => r.id === 'removable-rule-id');
  const global = body.rules.find((r) => r.id === 'default-ai-services');
  assert.equal(removable.removable, true);
  assert.equal(global.removable, false);
});

test('GET /api/sandbox-policies rejects an unknown sandbox name without spawning policy ls', async () => {
  resetLog();
  const { status } = await apiFetch('/api/sandbox-policies?name=no-such-sandbox');
  assert.equal(status, 400);
  // sbx policy ls <bogus> --json exits 0 and returns the *global* rules
  // (verified against the real CLI) — so it's specifically this call, not
  // just "any log entry", that must not have happened.
  assert.deepEqual(policyLsLoggedCommands(), []);
});

test('POST /api/sandbox/stop spawns exactly sbx stop <name>', async () => {
  resetLog();
  const { status, body } = await apiFetch('/api/sandbox/stop', {
    method: 'POST',
    body: JSON.stringify({ name: 'test-sandbox-1' }),
  });
  assert.equal(status, 200);
  assert.equal(body.ok, true);
  assert.deepEqual(mutatingLoggedCommands(), [['stop', 'test-sandbox-1']]);
});

test('POST /api/sandbox/stop rejects an unknown sandbox name without spawning stop', async () => {
  resetLog();
  const { status } = await apiFetch('/api/sandbox/stop', {
    method: 'POST',
    body: JSON.stringify({ name: 'no-such-sandbox' }),
  });
  assert.equal(status, 400);
  assert.deepEqual(mutatingLoggedCommands(), []);
});

test('POST /api/sandbox/remove spawns exactly sbx rm --force <name>', async () => {
  resetLog();
  const { status, body } = await apiFetch('/api/sandbox/remove', {
    method: 'POST',
    body: JSON.stringify({ name: 'test-sandbox-2' }),
  });
  assert.equal(status, 200);
  assert.equal(body.ok, true);
  assert.deepEqual(mutatingLoggedCommands(), [['rm', '--force', 'test-sandbox-2']]);
});

test('POST /api/sandbox/remove prunes that sandbox out of config.sandboxArgs', async () => {
  // Seed a stored args tail the way a real run would.
  await apiFetch('/api/sandbox/run', {
    method: 'POST',
    body: JSON.stringify({ name: 'test-sandbox-1', args: ['--model', 'opusplan'] }),
  });
  assert.ok(Object.prototype.hasOwnProperty.call(readConfig().sandboxArgs, 'test-sandbox-1'));

  resetLog();
  const { status } = await apiFetch('/api/sandbox/remove', {
    method: 'POST',
    body: JSON.stringify({ name: 'test-sandbox-1' }),
  });
  assert.equal(status, 200);
  assert.ok(!Object.prototype.hasOwnProperty.call(readConfig().sandboxArgs, 'test-sandbox-1'));
});

test('POST /api/sandbox/run hands the built argv to the launcher and persists the args text', async () => {
  resetLog();
  const { status, body } = await apiFetch('/api/sandbox/run', {
    method: 'POST',
    body: JSON.stringify({ name: 'test-sandbox-1', args: ['--model', 'opusplan'] }),
  });
  assert.equal(status, 200);
  assert.equal(body.ok, true);
  assert.deepEqual(launcherCalls, [['sbx', 'run', '--name', 'test-sandbox-1', '--', '--model', 'opusplan']]);
  assert.equal(readConfig().sandboxArgs['test-sandbox-1'], '--model opusplan');
});

test('POST /api/sandbox/run omits the -- separator when no args are given', async () => {
  resetLog();
  const { status } = await apiFetch('/api/sandbox/run', {
    method: 'POST',
    body: JSON.stringify({ name: 'test-sandbox-2' }),
  });
  assert.equal(status, 200);
  assert.deepEqual(launcherCalls, [['sbx', 'run', '--name', 'test-sandbox-2']]);
});

test('POST /api/sandbox/run rejects too many agent-argument tokens without calling the launcher', async () => {
  resetLog();
  const tooMany = Array.from({ length: 33 }, (_, i) => `t${i}`);
  const { status } = await apiFetch('/api/sandbox/run', {
    method: 'POST',
    body: JSON.stringify({ name: 'test-sandbox-1', args: tooMany }),
  });
  assert.equal(status, 400);
  assert.deepEqual(launcherCalls, []);
});

test('POST /api/sandbox/run rejects a control character in an agent argument without calling the launcher', async () => {
  resetLog();
  const { status } = await apiFetch('/api/sandbox/run', {
    method: 'POST',
    body: JSON.stringify({ name: 'test-sandbox-1', args: ['a\nb'] }),
  });
  assert.equal(status, 400);
  assert.deepEqual(launcherCalls, []);
});

test('POST /api/sandbox/run rejects an unknown sandbox name without calling the launcher', async () => {
  resetLog();
  const { status } = await apiFetch('/api/sandbox/run', {
    method: 'POST',
    body: JSON.stringify({ name: 'no-such-sandbox', args: [] }),
  });
  assert.equal(status, 400);
  assert.deepEqual(launcherCalls, []);
});

test('POST /api/sandbox/policy add spawns the allow rule with --sandbox always present', async () => {
  resetLog();
  const { status, body } = await apiFetch('/api/sandbox/policy', {
    method: 'POST',
    body: JSON.stringify({ name: 'test-sandbox-1', action: 'add', decision: 'allow', resources: ['example.com'] }),
  });
  assert.equal(status, 200);
  assert.equal(body.ok, true);
  assert.deepEqual(mutatingLoggedCommands(), [
    ['policy', 'allow', 'network', '--sandbox', 'test-sandbox-1', 'example.com'],
  ]);
  // The shim is a stub that always answers `policy ls` with the same canned
  // two rules, regardless of prior writes — it can't prove the mutation
  // actually changed anything. The argv assertion above is what proves the
  // right command ran; this just checks the re-list call happened and its
  // shape made it into the response.
  assert.deepEqual(policyLsLoggedCommands(), [['policy', 'ls', 'test-sandbox-1', '--json']]);
  assert.equal(body.rules.length, 2);
});

test('POST /api/sandbox/policy add rejects a decision that is neither allow nor deny', async () => {
  resetLog();
  const { status } = await apiFetch('/api/sandbox/policy', {
    method: 'POST',
    body: JSON.stringify({ name: 'test-sandbox-1', action: 'add', decision: 'maybe', resources: ['example.com'] }),
  });
  assert.equal(status, 400);
  assert.deepEqual(mutatingLoggedCommands(), []);
});

test('POST /api/sandbox/policy add rejects an invalid resource without spawning anything', async () => {
  resetLog();
  const { status } = await apiFetch('/api/sandbox/policy', {
    method: 'POST',
    body: JSON.stringify({ name: 'test-sandbox-1', action: 'add', decision: 'allow', resources: ['a b'] }),
  });
  assert.equal(status, 400);
  assert.deepEqual(mutatingLoggedCommands(), []);
});

test('POST /api/sandbox/policy remove spawns rm by rule id', async () => {
  resetLog();
  const { status, body } = await apiFetch('/api/sandbox/policy', {
    method: 'POST',
    body: JSON.stringify({ name: 'test-sandbox-1', action: 'remove', ruleId: 'removable-rule-id' }),
  });
  assert.equal(status, 200);
  assert.equal(body.ok, true);
  assert.deepEqual(mutatingLoggedCommands(), [
    ['policy', 'rm', 'network', '--sandbox', 'test-sandbox-1', '--id', 'removable-rule-id'],
  ]);
});

test('POST /api/sandbox/policy remove refuses a non-removable (global) rule id without spawning a removal', async () => {
  resetLog();
  const { status } = await apiFetch('/api/sandbox/policy', {
    method: 'POST',
    body: JSON.stringify({ name: 'test-sandbox-1', action: 'remove', ruleId: 'default-ai-services' }),
  });
  assert.equal(status, 400);
  assert.deepEqual(mutatingLoggedCommands(), []);
});

test('a missing token is rejected with 403', async () => {
  const res = await fetch(`${baseUrl}/api/sandboxes`, { headers: { 'x-sbx-helper-token': '' } });
  assert.equal(res.status, 403);
});

test('a wrong token is rejected with 403', async () => {
  const res = await fetch(`${baseUrl}/api/sandboxes`, { headers: { 'x-sbx-helper-token': 'wrong-token-value-000000' } });
  assert.equal(res.status, 403);
});

test('a same-character-length multi-byte token is rejected with 403, not a 500 from timingSafeEqual', async () => {
  // TOKEN is a 48-character hex string (all 1-byte ASCII). Swap one
  // character for a 2-byte UTF-8 character to get the same JS string
  // .length but a different Buffer byte length — the exact mismatch that
  // used to reach timingSafeEqual() and throw a RangeError.
  const forged = 'é' + 'a'.repeat(47);
  const res = await fetch(`${baseUrl}/api/sandboxes`, { headers: { 'x-sbx-helper-token': forged } });
  assert.equal(res.status, 403);
});

test('an infrastructure failure (sbx ls itself failing) is reported as 502, not 400', async () => {
  resetLog();
  process.env.SBX_SHIM_FAIL_LS = '1';
  try {
    const { status } = await apiFetch('/api/sandbox/stop', {
      method: 'POST',
      body: JSON.stringify({ name: 'test-sandbox-1' }),
    });
    assert.equal(status, 502);
  } finally {
    delete process.env.SBX_SHIM_FAIL_LS;
  }
});
