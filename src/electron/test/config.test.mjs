import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { loadConfig, saveConfig, defaultConfig, relativizePreset, absolutizePreset } from '../lib/config.mjs';

function tmpConfigPath() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sbx-helper-cfg-'));
  return path.join(dir, 'sbx-helper.json');
}

test('defaultConfig includes an empty sandboxArgs map', () => {
  assert.deepEqual(defaultConfig().sandboxArgs, {});
});

test('loadConfig writes and returns defaults when the file is missing', () => {
  const p = tmpConfigPath();
  const { config, error } = loadConfig(p);
  assert.equal(error, null);
  assert.equal(config.defaultTemplate, defaultConfig().defaultTemplate);
  assert.ok(fs.existsSync(p));
});

test('loadConfig falls back to defaults on malformed JSON, without throwing', () => {
  const p = tmpConfigPath();
  fs.writeFileSync(p, '{ not json');
  const { config, error } = loadConfig(p);
  assert.ok(error);
  assert.deepEqual(config.presets, []);
});

test('config round-trips through save/load', () => {
  const p = tmpConfigPath();
  const cfg = { ...defaultConfig(), rootPath: '/tmp/x', defaultTemplate: 'tpl:v1' };
  saveConfig(p, cfg);
  const { config } = loadConfig(p);
  assert.equal(config.rootPath, '/tmp/x');
  assert.equal(config.defaultTemplate, 'tpl:v1');
});

test('saveConfig leaves no leftover temp file behind', () => {
  const p = tmpConfigPath();
  saveConfig(p, defaultConfig());
  const dir = path.dirname(p);
  const leftovers = fs.readdirSync(dir).filter((f) => f !== path.basename(p));
  assert.deepEqual(leftovers, []);
});

// A hand-edited (or corrupted-but-still-valid-JSON) config with the wrong
// type for a field used to propagate straight through the shallow
// {...defaultConfig(), ...parsed} merge — e.g. "presets": null overriding
// the default [], then crashing the first .findIndex() call on it.
test('loadConfig coerces a non-array presets value back to the default', () => {
  const p = tmpConfigPath();
  fs.writeFileSync(p, JSON.stringify({ presets: null }));
  const { config } = loadConfig(p);
  assert.deepEqual(config.presets, []);
});

test('loadConfig coerces a non-array recentRoots value back to the default', () => {
  const p = tmpConfigPath();
  fs.writeFileSync(p, JSON.stringify({ recentRoots: 'not-an-array' }));
  const { config } = loadConfig(p);
  assert.deepEqual(config.recentRoots, []);
});

test('loadConfig coerces a non-array ignoreFolders value back to the default', () => {
  const p = tmpConfigPath();
  fs.writeFileSync(p, JSON.stringify({ ignoreFolders: 42 }));
  const { config } = loadConfig(p);
  assert.deepEqual(config.ignoreFolders, defaultConfig().ignoreFolders);
});

test('loadConfig coerces a non-object sandboxArgs value back to the default', () => {
  const p = tmpConfigPath();
  fs.writeFileSync(p, JSON.stringify({ sandboxArgs: ['not', 'an', 'object'] }));
  const { config } = loadConfig(p);
  assert.deepEqual(config.sandboxArgs, {});
});

test('loadConfig coerces a null sandboxArgs value back to the default', () => {
  const p = tmpConfigPath();
  fs.writeFileSync(p, JSON.stringify({ sandboxArgs: null }));
  const { config } = loadConfig(p);
  assert.deepEqual(config.sandboxArgs, {});
});

test('preset paths relativize and re-absolutize', () => {
  const root = '/Users/alexalbu/repos/nho';
  const preset = {
    name: 'p1',
    rootPath: root,
    template: 'tpl',
    sandboxName: null,
    clone: false,
    editable: [path.join(root, 'Consent-register/NHO.0476.ConsentRegister.Web')],
    readOnly: [path.join(root, 'AccessHubPortal/NHO.AccessHub.Web')],
  };
  const rel = relativizePreset(root, preset);
  assert.equal(rel.editable[0], 'Consent-register/NHO.0476.ConsentRegister.Web');
  assert.equal(rel.readOnly[0], 'AccessHubPortal/NHO.AccessHub.Web');

  const abs = absolutizePreset(rel);
  assert.equal(abs.editable[0], preset.editable[0]);
  assert.equal(abs.readOnly[0], preset.readOnly[0]);
});
