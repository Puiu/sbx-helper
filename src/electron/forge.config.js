// forge.config.js — CommonJS, matching Electron Forge's own documented
// default format. package.json intentionally has no "type": "module" set,
// so this plain .js file is interpreted as CommonJS by Node with no extra
// config; every file that's actually part of the app is .mjs and unaffected
// by that field either way.
//
// Minimal on purpose: this app is macOS-only, so there's exactly one maker.

// This app has zero runtime npm dependencies (only Electron itself, which
// the packager provides separately) — everything under node_modules/ here
// is devDependencies for the build tooling and has no business being inside
// the shipped app. Keep only what electron-main.mjs actually needs at
// runtime: itself, server.mjs, lib/, public/, and package.json (Electron
// reads "main" from it).
const KEEP = new Set(['electron-main.mjs', 'server.mjs', 'lib', 'public', 'package.json']);

module.exports = {
  packagerConfig: {
    asar: true,
    name: 'sbx-helper',
    ignore: (file) => {
      if (file === '') return false; // the project root itself
      const top = file.replace(/^\//, '').split('/')[0];
      return !KEEP.has(top);
    },
  },
  rebuildConfig: {},
  makers: [{ name: '@electron-forge/maker-zip', platforms: ['darwin'] }],
};
