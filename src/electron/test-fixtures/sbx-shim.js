#!/usr/bin/env node
// A fake `sbx` binary for test/server-sandboxes.test.mjs. The test copies
// this file into a temp bin directory as the exact name `sbx` (PATH lookup
// is by exact filename) and prepends that directory to PATH, so
// spawn('sbx', ...) resolves here instead of the real CLI.
//
// CommonJS on purpose, matching forge.config.js's precedent: package.json
// has no "type": "module", so an extension-less script run via its shebang
// is safest as plain CommonJS rather than relying on ESM syntax detection.
//
// Answers `ls --json` and `policy ls <name> --json` with canned JSON, and
// logs the argv of EVERY invocation (not just mutating ones) as one JSON
// line to $SBX_SHIM_LOG. Logging reads too matters: a test asserting "the
// server didn't spawn policy ls for an unknown name" needs the shim to
// record policy-ls calls, or the assertion has nothing to fail against even
// if the server were wrong. The test file filters the log by command shape
// (e.g. only the "stop" or "policy allow" entries) rather than expecting it
// empty, since a read like `ls --json` legitimately happens on every
// request as part of the sandbox-name allowlist check.
//
// SBX_SHIM_FAIL_LS=1 makes the `ls --json` branch fail (exit 1, message on
// stderr) to simulate sbx itself being broken/unavailable.

const fs = require('fs');

const args = process.argv.slice(2);

function appendLog(argv) {
  fs.appendFileSync(process.env.SBX_SHIM_LOG, JSON.stringify(argv) + '\n');
}

appendLog(args);

if (args[0] === 'ls' && args.includes('--json')) {
  if (process.env.SBX_SHIM_FAIL_LS) {
    process.stderr.write('sbx: simulated failure (SBX_SHIM_FAIL_LS)\n');
    process.exit(1);
  }
  process.stdout.write(JSON.stringify({
    sandboxes: [
      { name: 'test-sandbox-1', id: 'id-1', agent: 'claude', status: 'running', workspaces: ['/tmp/ws1'] },
      { name: 'test-sandbox-2', id: 'id-2', agent: 'opencode', status: 'stopped', workspaces: ['/tmp/ws2'] },
    ],
  }));
  process.exit(0);
}

if (args[0] === 'policy' && args[1] === 'ls') {
  const name = args[2];
  process.stdout.write(JSON.stringify({
    rules: [
      {
        id: 'removable-rule-id',
        name: 'removable-rule-id',
        policy_id: 'local-policy',
        scope: `sandbox:${name}`,
        applies_to: `sandbox:${name}`,
        resource_type: 'network',
        decision: 'deny',
        resources: ['ads.example.com'],
        origin: 'local',
        layer: 'local',
        status: 'active',
        editable: true,
      },
      {
        id: 'default-ai-services',
        name: 'default-ai-services',
        policy_id: 'local-policy',
        scope: 'global',
        applies_to: 'all',
        resource_type: 'network',
        decision: 'allow',
        resources: ['api.anthropic.com:443'],
        origin: 'local',
        layer: 'local',
        status: 'active',
        editable: true,
      },
    ],
  }));
  process.exit(0);
}

const mutating =
  args[0] === 'stop' ||
  args[0] === 'rm' ||
  (args[0] === 'policy' && ['allow', 'deny', 'rm'].includes(args[1]));

if (mutating) {
  process.exit(0);
}

process.exit(1);
