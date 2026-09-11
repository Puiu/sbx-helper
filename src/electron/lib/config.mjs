// lib/config.mjs — server-only. Config file load/save and preset path
// relativizing. Uses node:fs, so this never gets served to the browser.

import fs from 'node:fs';
import path from 'node:path';

export function defaultConfig() {
  return {
    rootPath: process.cwd(),
    recentRoots: [],
    defaultTemplate: 'claude-sbx-dotnet10:v2',
    agent: 'claude',
    maxDepth: 3,
    ignoreFolders: ['.git', 'node_modules', 'bin', 'obj', '.vs', '.idea'],
    port: 7777,
    presets: [],
    sandboxArgs: {},
  };
}

function isPlainObject(v) {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

// A shallow {...defaultConfig(), ...parsed} merge lets a hand-edited (or
// corrupted-but-still-valid-JSON) config file's wrong-typed field silently
// override a sane default — e.g. "presets": null overriding the default []
// and crashing the first .findIndex() call on it. Guard the fields callers
// actually iterate or index into.
function coerceTypes(merged) {
  const defaults = defaultConfig();
  if (!Array.isArray(merged.presets)) merged.presets = defaults.presets;
  if (!Array.isArray(merged.recentRoots)) merged.recentRoots = defaults.recentRoots;
  if (!Array.isArray(merged.ignoreFolders)) merged.ignoreFolders = defaults.ignoreFolders;
  if (!isPlainObject(merged.sandboxArgs)) merged.sandboxArgs = defaults.sandboxArgs;
  return merged;
}

/** Missing config → write and return defaults. Malformed → defaults + error message. */
export function loadConfig(configPath) {
  if (!fs.existsSync(configPath)) {
    const fresh = defaultConfig();
    saveConfig(configPath, fresh);
    return { config: fresh, error: null };
  }
  try {
    const raw = fs.readFileSync(configPath, 'utf8');
    const parsed = JSON.parse(raw);
    return { config: coerceTypes({ ...defaultConfig(), ...parsed }), error: null };
  } catch (err) {
    return { config: defaultConfig(), error: err.message };
  }
}

/**
 * Writes via a temp file + rename in the same directory, rather than
 * writeFileSync directly onto configPath — a rename is atomic on the same
 * filesystem, so a crash or full disk mid-write can't leave a truncated
 * config behind (which loadConfig would otherwise silently treat as
 * malformed JSON and fall back to defaults, losing every saved preset).
 */
export function saveConfig(configPath, config) {
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  const tmpPath = path.join(path.dirname(configPath), `.${path.basename(configPath)}.tmp-${process.pid}-${Date.now()}`);
  fs.writeFileSync(tmpPath, JSON.stringify(config, null, 2) + '\n');
  fs.renameSync(tmpPath, configPath);
}

/** Absolute editable/readOnly paths -> stored relative to the preset's own rootPath. */
export function relativizePreset(rootPath, preset) {
  return {
    ...preset,
    editable: preset.editable.map((p) => path.relative(rootPath, p)),
    readOnly: preset.readOnly.map((p) => path.relative(rootPath, p)),
  };
}

/** Stored relative paths -> absolute paths under the preset's rootPath. */
export function absolutizePreset(preset) {
  return {
    editable: preset.editable.map((r) => path.resolve(preset.rootPath, r)),
    readOnly: preset.readOnly.map((r) => path.resolve(preset.rootPath, r)),
  };
}
