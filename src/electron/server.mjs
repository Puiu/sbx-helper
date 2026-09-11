#!/usr/bin/env node
// sbx-helper — local web app that builds `sbx run` commands.
//
// Run:   node server.mjs
// Tests: node --test
//
// No npm dependencies. node:http + static files + a small JSON API.

import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { randomBytes, timingSafeEqual } from 'node:crypto';

import { loadConfig, saveConfig, relativizePreset } from './lib/config.mjs';
import { scanTree, completePath } from './lib/scan.mjs';
import { listTemplates } from './lib/templates.mjs';
import { launchInTerminal, copyToClipboard, revealInFinder } from './lib/terminal.mjs';
import { listSandboxes, listNetworkRules, runSbx } from './lib/sandboxes.mjs';
import { buildCommand, formatCommand } from './public/shared/command.mjs';
import { findAnyConflict } from './public/shared/selection.mjs';
import {
  buildRunExistingArgs,
  buildStopArgs,
  buildRemoveArgs,
  buildPolicyAddArgs,
  buildPolicyRemoveArgs,
  isValidNetworkResource,
  MAX_RESOURCES_PER_REQUEST,
} from './public/shared/sandbox-commands.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, 'public');
const CONFIG_PATH = process.env.SBX_HELPER_CONFIG || path.join(__dirname, 'sbx-helper.json');

// Random per-run token. Every /api/* request must carry it (see checkToken)
// — without this, any webpage in any browser tab could POST to localhost
// and start sandboxes.
const TOKEN = randomBytes(24).toString('hex');

const { config, error: configLoadError } = loadConfig(CONFIG_PATH);
if (configLoadError) {
  console.error(`sbx-helper: config error at ${CONFIG_PATH}, using defaults: ${configLoadError}`);
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
};

function persist() {
  saveConfig(CONFIG_PATH, config);
}

// Overridable so tests can exercise the routes that end in "open a terminal
// window" (apiRun, apiSandboxRun) without actually spawning osascript/open —
// see startServer()'s `launcher` option.
let launcher = launchInTerminal;

function sendJson(res, status, body) {
  const json = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(json);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    // Collect raw Buffer chunks and decode once at the end, rather than
    // `data += chunk` — that coerces each chunk to a string independently,
    // and a multi-byte UTF-8 character split across a chunk boundary
    // decodes to a replacement character on each half instead of the
    // original character once the halves are joined.
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 2_000_000) {
        reject(new Error('Payload too large.'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (chunks.length === 0) return resolve({});
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(new Error('Malformed JSON body.'));
      }
    });
    req.on('error', reject);
  });
}

// Blocks DNS rebinding: an attacker page could get a browser to fetch a
// domain that *resolves* to 127.0.0.1, reaching this server even though we
// only bind loopback. The Host header on that request carries the attacker's
// domain name, not "127.0.0.1" or "localhost", so this check catches it.
function checkHost(req) {
  const host = req.headers.host || '';
  const hostname = host.split(':')[0];
  return hostname === '127.0.0.1' || hostname === 'localhost';
}

function checkToken(req) {
  const header = req.headers['x-sbx-helper-token'];
  if (typeof header !== 'string') return false;
  // Compare byte length, not JS string (UTF-16 code unit) length —
  // timingSafeEqual requires equal-length buffers and throws otherwise. A
  // header the same *character* length as TOKEN but containing a multi-byte
  // character would pass the old `.length` check yet produce a longer
  // Buffer, turning a should-be-403 into an uncaught-exception 500.
  const headerBuf = Buffer.from(header);
  const tokenBuf = Buffer.from(TOKEN);
  if (headerBuf.length !== tokenBuf.length) return false;
  return timingSafeEqual(headerBuf, tokenBuf);
}

function serveStatic(req, res, pathname) {
  const rel = pathname === '/' ? '/index.html' : pathname;
  const filePath = path.normalize(path.join(PUBLIC_DIR, rel));
  // The trailing separator matters: without it, a sibling directory that
  // merely starts with the same characters (e.g. PUBLIC_DIR + "X") would
  // also pass `startsWith`. Not reachable today (the URL parser normalizes
  // ".." away before this ever sees a pathname), but one added decode step
  // away from being one — worth the one extra character.
  if (!filePath.startsWith(PUBLIC_DIR + path.sep)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }
  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream' });
    res.end(data);
  });
}

// -- API handlers ------------------------------------------------------

async function apiState(res) {
  const tree = scanTree(config.rootPath, config.maxDepth, config.ignoreFolders);
  const templates = await listTemplates();
  sendJson(res, 200, { config, tree, templates });
}

async function apiScan(req, res) {
  const body = await readJson(req);
  const rootPath = typeof body.rootPath === 'string' ? body.rootPath.trim() : '';
  if (!rootPath) return sendJson(res, 400, { error: 'rootPath is required.' });

  const resolved = path.resolve(rootPath);
  let stat;
  try {
    stat = fs.statSync(resolved);
  } catch {
    return sendJson(res, 400, { error: `Not found: ${resolved}` });
  }
  if (!stat.isDirectory()) return sendJson(res, 400, { error: `Not a directory: ${resolved}` });

  config.rootPath = resolved;
  config.recentRoots = [resolved, ...(config.recentRoots || []).filter((r) => r !== resolved)].slice(0, 8);
  persist();

  const tree = scanTree(resolved, config.maxDepth, config.ignoreFolders);
  sendJson(res, 200, { config, tree });
}

function apiCompletePath(req, res, url) {
  const prefix = url.searchParams.get('prefix') || '';
  const suggestions = completePath(prefix, config.ignoreFolders);
  sendJson(res, 200, { suggestions });
}

async function apiConfig(req, res) {
  const body = await readJson(req);
  if (typeof body.defaultTemplate === 'string' && body.defaultTemplate.trim()) {
    config.defaultTemplate = body.defaultTemplate.trim();
  }
  persist();
  sendJson(res, 200, { config });
}

async function apiPresets(req, res) {
  const body = await readJson(req);

  if (body.action === 'save') {
    const name = typeof body.name === 'string' ? body.name.trim() : '';
    if (!name) return sendJson(res, 400, { error: 'Preset name is required.' });
    const isStringArray = (v) => Array.isArray(v) && v.every((p) => typeof p === 'string');
    if (!isStringArray(body.editable) || body.editable.length === 0) {
      return sendJson(res, 400, { error: 'Select at least one editable folder before saving.' });
    }
    if (body.readOnly !== undefined && !isStringArray(body.readOnly)) {
      return sendJson(res, 400, { error: 'Read-only folders must be a list of paths.' });
    }
    const preset = relativizePreset(config.rootPath, {
      name,
      rootPath: config.rootPath,
      template: typeof body.template === 'string' && body.template.trim() ? body.template.trim() : config.defaultTemplate,
      sandboxName: body.sandboxName || null,
      clone: !!body.clone,
      editable: body.editable,
      readOnly: Array.isArray(body.readOnly) ? body.readOnly : [],
    });
    const idx = config.presets.findIndex((p) => p.name === name);
    const overwritten = idx >= 0;
    if (idx >= 0) config.presets[idx] = preset; else config.presets.push(preset);
    persist();
    return sendJson(res, 200, { presets: config.presets, overwritten });
  }

  if (body.action === 'delete') {
    const name = typeof body.name === 'string' ? body.name : '';
    config.presets = config.presets.filter((p) => p.name !== name);
    persist();
    return sendJson(res, 200, { presets: config.presets });
  }

  sendJson(res, 400, { error: 'Unknown action.' });
}

async function apiRun(req, res) {
  const body = await readJson(req);
  const editable = Array.isArray(body.editable) ? body.editable : [];
  const readOnly = Array.isArray(body.readOnly) ? body.readOnly : [];

  if (editable.length === 0) {
    return sendJson(res, 400, { ok: false, error: 'Select at least one editable folder.' });
  }

  const allPaths = [...editable, ...readOnly];
  for (const p of allPaths) {
    if (typeof p !== 'string' || !path.isAbsolute(p)) {
      return sendJson(res, 400, { ok: false, error: 'Every workspace path must be an absolute path.' });
    }
    if (!fs.existsSync(p)) {
      return sendJson(res, 400, { ok: false, error: `Folder not found: ${p}` });
    }
  }
  const conflict = findAnyConflict(allPaths);
  if (conflict) return sendJson(res, 400, { ok: false, error: `Overlapping selection: ${conflict}` });

  const template = typeof body.template === 'string' && body.template.trim() ? body.template.trim() : config.defaultTemplate;

  let args, display;
  try {
    ({ args, display } = buildCommand({
      agent: config.agent,
      template,
      name: typeof body.name === 'string' ? body.name : null,
      clone: !!body.clone,
      editable,
      readOnly,
      primary: typeof body.primary === 'string' ? body.primary : null,
    }));
  } catch (err) {
    return sendJson(res, 400, { ok: false, error: err.message });
  }

  config.defaultTemplate = template;
  persist();

  const result = await launcher(args);
  sendJson(res, result.ok ? 200 : 502, { ok: result.ok, error: result.error ?? null, display });
}

async function apiClipboard(req, res) {
  const body = await readJson(req);
  const text = typeof body.text === 'string' ? body.text : '';
  if (!text) return sendJson(res, 400, { ok: false, error: 'No text provided.' });
  const result = await copyToClipboard(text);
  sendJson(res, result.ok ? 200 : 502, result);
}

async function apiReveal(req, res) {
  const body = await readJson(req);
  const dirPath = typeof body.path === 'string' ? body.path : '';
  if (!dirPath || !path.isAbsolute(dirPath)) {
    return sendJson(res, 400, { ok: false, error: 'path must be an absolute path.' });
  }
  let stat;
  try {
    stat = fs.statSync(dirPath);
  } catch {
    return sendJson(res, 400, { ok: false, error: `Folder not found: ${dirPath}` });
  }
  if (!stat.isDirectory()) return sendJson(res, 400, { ok: false, error: `Not a directory: ${dirPath}` });

  const result = await revealInFinder(dirPath);
  sendJson(res, result.ok ? 200 : 502, result);
}

// -- sandboxes tab API handlers -------------------------------------------
//
// The sandbox name is checked against a fresh `sbx ls` on every request
// (never cached) — an allowlist of names that actually exist, not just a
// syntax check. This matters beyond the obvious "don't act on a name that
// isn't really a sandbox": `sbx policy ls <bogus-name> --json` exits 0 and
// happily returns the *global* rules, so without this check the policy
// endpoints would render and could be tricked into touching global policy
// under the guise of a sandbox that doesn't exist.

async function requireKnownSandbox(name) {
  if (typeof name !== 'string' || !name.trim()) {
    return { ok: false, status: 400, error: 'A sandbox name is required.' };
  }
  const { ok, sandboxes, error } = await listSandboxes();
  // Distinguish "sbx itself is unavailable" (502 — an infrastructure
  // problem) from "that sandbox genuinely doesn't exist" (400 — a bad
  // request) — otherwise a broken/missing sbx binary presents to the user
  // as an invalid sandbox name, which is misleading and sends them looking
  // in the wrong place.
  if (!ok) return { ok: false, status: 502, error: error || 'Could not list sandboxes.' };
  const sandbox = sandboxes.find((s) => s.name === name);
  if (!sandbox) return { ok: false, status: 400, error: `Unknown sandbox: ${name}` };
  return { ok: true, sandbox };
}

async function apiSandboxes(res) {
  const { ok, sandboxes, error } = await listSandboxes();
  sendJson(res, ok ? 200 : 502, { sandboxes, error });
}

async function apiSandboxPolicies(req, res, url) {
  const name = url.searchParams.get('name') || '';
  const check = await requireKnownSandbox(name);
  if (!check.ok) return sendJson(res, check.status, { error: check.error });
  const { ok, rules, error } = await listNetworkRules(name);
  sendJson(res, ok ? 200 : 502, { rules, error });
}

async function apiSandboxStop(req, res) {
  const body = await readJson(req);
  const name = typeof body.name === 'string' ? body.name : '';
  const check = await requireKnownSandbox(name);
  if (!check.ok) return sendJson(res, check.status, { ok: false, error: check.error });

  let args;
  try {
    args = buildStopArgs(name);
  } catch (err) {
    return sendJson(res, 400, { ok: false, error: err.message });
  }
  const result = await runSbx(args.slice(1)); // drop the leading 'sbx' — spawn() already names the program
  sendJson(res, result.ok ? 200 : 502, { ok: result.ok, error: result.ok ? null : result.stderr });
}

async function apiSandboxRemove(req, res) {
  const body = await readJson(req);
  const name = typeof body.name === 'string' ? body.name : '';
  const check = await requireKnownSandbox(name);
  if (!check.ok) return sendJson(res, check.status, { ok: false, error: check.error });

  let args;
  try {
    args = buildRemoveArgs(name);
  } catch (err) {
    return sendJson(res, 400, { ok: false, error: err.message });
  }
  const result = await runSbx(args.slice(1));
  if (result.ok && config.sandboxArgs && Object.prototype.hasOwnProperty.call(config.sandboxArgs, name)) {
    // Otherwise a stale args tail lingers forever and a later sandbox
    // recreated under the same name silently inherits it.
    delete config.sandboxArgs[name];
    persist();
  }
  sendJson(res, result.ok ? 200 : 502, { ok: result.ok, error: result.ok ? null : result.stderr });
}

// The agent-args tail is unavoidably a client-supplied string (that's the
// feature). It's validated structurally — token count, length, no control
// characters — by buildRunExistingArgs (via public/shared/sandbox-commands.mjs's
// validateAgentArgs; the single implementation the client's live preview
// also runs through, per this file's architecture rule), then passed to
// spawn() as discrete argv elements, never through a shell, and reaches the
// temp .command script only via formatCommand()'s quotePosix. See
// CLAUDE.md's security section for the residual-risk note this widens
// beyond /api/run's "paths only" contract.
async function apiSandboxRun(req, res) {
  const body = await readJson(req);
  const name = typeof body.name === 'string' ? body.name : '';
  const check = await requireKnownSandbox(name);
  if (!check.ok) return sendJson(res, check.status, { ok: false, error: check.error });

  const agentArgs = Array.isArray(body.args) ? body.args : [];

  let args, display;
  try {
    args = buildRunExistingArgs({ name, agentArgs });
    display = formatCommand(args);
  } catch (err) {
    return sendJson(res, 400, { ok: false, error: err.message });
  }

  // Persisted regardless of whether the launch below actually succeeds —
  // the typed args reflect the user's intent, and a launch failure (no
  // terminal app available, say) isn't a reason to discard them.
  config.sandboxArgs = config.sandboxArgs || {};
  if (agentArgs.length > 0) config.sandboxArgs[name] = formatCommand(agentArgs);
  else delete config.sandboxArgs[name];
  persist();

  const result = await launcher(args);
  sendJson(res, result.ok ? 200 : 502, { ok: result.ok, error: result.ok ? null : result.error, display });
}

async function apiSandboxPolicyAdd(name, body, res) {
  const decision = body.decision;
  const resources = Array.isArray(body.resources) ? body.resources : [];
  if (decision !== 'allow' && decision !== 'deny') {
    return sendJson(res, 400, { ok: false, error: 'decision must be "allow" or "deny".' });
  }
  if (resources.length === 0 || resources.length > MAX_RESOURCES_PER_REQUEST || !resources.every(isValidNetworkResource)) {
    return sendJson(res, 400, { ok: false, error: 'One or more resources are invalid.' });
  }

  let args;
  try {
    args = buildPolicyAddArgs({ name, decision, resources });
  } catch (err) {
    return sendJson(res, 400, { ok: false, error: err.message });
  }
  const result = await runSbx(args.slice(1));
  if (!result.ok) return sendJson(res, 502, { ok: false, error: result.stderr });

  const relisted = await listNetworkRules(name);
  sendJson(res, 200, { ok: true, rules: relisted.rules, error: relisted.ok ? null : relisted.error });
}

async function apiSandboxPolicyRemove(name, body, res) {
  // Re-validate against a fresh list rather than trusting the client's
  // ruleId/resource: only a rule this endpoint's own classification calls
  // "removable" (sandbox-scoped AND editable) may be removed, so a client
  // can't smuggle a global or kit rule's id through here.
  const relisted = await listNetworkRules(name);
  if (!relisted.ok) return sendJson(res, 502, { ok: false, error: relisted.error });

  const ruleId = typeof body.ruleId === 'string' ? body.ruleId : null;
  const resource = typeof body.resource === 'string' ? body.resource : null;
  const target = ruleId
    ? relisted.rules.find((r) => r.id === ruleId)
    : resource
      ? relisted.rules.find((r) => r.resources.includes(resource))
      : null;
  if (!target || !target.removable) {
    return sendJson(res, 400, { ok: false, error: 'That rule cannot be removed from here.' });
  }

  let args;
  try {
    args = buildPolicyRemoveArgs({ name, ruleId, resource });
  } catch (err) {
    return sendJson(res, 400, { ok: false, error: err.message });
  }
  const result = await runSbx(args.slice(1));
  if (!result.ok) return sendJson(res, 502, { ok: false, error: result.stderr });

  const after = await listNetworkRules(name);
  sendJson(res, 200, { ok: true, rules: after.rules, error: after.ok ? null : after.error });
}

async function apiSandboxPolicy(req, res) {
  const body = await readJson(req);
  const name = typeof body.name === 'string' ? body.name : '';
  const check = await requireKnownSandbox(name);
  if (!check.ok) return sendJson(res, check.status, { ok: false, error: check.error });

  if (body.action === 'add') return apiSandboxPolicyAdd(name, body, res);
  if (body.action === 'remove') return apiSandboxPolicyRemove(name, body, res);
  return sendJson(res, 400, { ok: false, error: 'Unknown action.' });
}

// -- routing -------------------------------------------------------------

const ROUTES = [
  ['GET', '/api/state', (req, res) => apiState(res)],
  ['GET', '/api/complete-path', apiCompletePath],
  ['POST', '/api/scan', apiScan],
  ['POST', '/api/config', apiConfig],
  ['POST', '/api/presets', apiPresets],
  ['POST', '/api/run', apiRun],
  ['POST', '/api/clipboard', apiClipboard],
  ['POST', '/api/reveal', apiReveal],
  ['GET', '/api/sandboxes', (req, res) => apiSandboxes(res)],
  ['GET', '/api/sandbox-policies', apiSandboxPolicies],
  ['POST', '/api/sandbox/stop', apiSandboxStop],
  ['POST', '/api/sandbox/remove', apiSandboxRemove],
  ['POST', '/api/sandbox/run', apiSandboxRun],
  ['POST', '/api/sandbox/policy', apiSandboxPolicy],
];

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || '127.0.0.1'}`);

    if (url.pathname.startsWith('/api/')) {
      if (!checkHost(req)) return sendJson(res, 403, { error: 'Forbidden host.' });
      if (!checkToken(req)) return sendJson(res, 403, { error: 'Missing or invalid token.' });
      const route = ROUTES.find(([method, p]) => method === req.method && p === url.pathname);
      if (!route) return sendJson(res, 404, { error: 'Not found.' });
      return await route[2](req, res, url);
    }

    return serveStatic(req, res, url.pathname);
  } catch (err) {
    sendJson(res, 500, { error: err.message });
  }
});

function listen(preferredPort) {
  return new Promise((resolve, reject) => {
    const onError = (err) => {
      if (err.code === 'EADDRINUSE' && preferredPort !== 0) {
        server.removeListener('error', onError);
        resolve(listen(0)); // 0 = let the OS pick a free port
      } else {
        reject(err);
      }
    };
    server.once('error', onError);
    server.listen(preferredPort, '127.0.0.1', () => {
      server.removeListener('error', onError);
      resolve(server.address().port);
    });
  });
}

function openBrowser(url) {
  try {
    spawn('open', [url], { stdio: 'ignore', detached: true }).unref();
  } catch {
    // Not fatal — the URL is printed either way.
  }
}

/**
 * Starts listening and returns { port, token, url }. Pass
 * { openBrowser: false } when something else (e.g. an Electron window) is
 * going to point itself at the URL instead of the system browser. Pass
 * { launcher } to replace launchInTerminal for both apiRun and
 * apiSandboxRun — the only way to exercise those routes' validation without
 * really opening a terminal window (see test/server-sandboxes.test.mjs).
 */
export async function startServer({ openBrowser: shouldOpenBrowser = true, launcher: customLauncher } = {}) {
  if (customLauncher) launcher = customLauncher;
  const actualPort = await listen(config.port || 7777);
  const url = `http://127.0.0.1:${actualPort}/?t=${TOKEN}`;
  console.log(`sbx-helper running at ${url}`);
  if (shouldOpenBrowser) openBrowser(url);
  return { port: actualPort, token: TOKEN, url };
}

/** Closes the listener. Lets a test process that called startServer() exit. */
export function stopServer() {
  return new Promise((resolve) => server.close(() => resolve()));
}

// Only auto-start when this file is run directly (`node server.mjs`), not
// when something else imports startServer() to control the lifecycle itself.
if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  startServer();
}
