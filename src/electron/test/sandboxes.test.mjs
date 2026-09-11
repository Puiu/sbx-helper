import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { parseSandboxLs, formatPort, parseNetworkRules } from '../lib/sandboxes.mjs';

describe('parseSandboxLs', () => {
  test('parses the sandboxes array from real sbx ls --json output', () => {
    const stdout = JSON.stringify({
      sandboxes: [
        {
          name: '24114-natt-sync-selskap',
          id: '99ea36b1-c896-4371-9bec-35befe90e4e6',
          agent: 'claude',
          status: 'running',
          workspaces: ['/Users/alexalbu/repos/nho/ForeningshubV2/NHO.0474.Federationhub.Api'],
        },
        {
          name: 'opencode-os-vitals',
          id: 'f1b82fae-05aa-46cd-9eb2-826471fa4724',
          agent: 'opencode',
          status: 'stopped',
          workspaces: ['/Users/alexalbu/repos/my-apps/os-vitals'],
        },
      ],
    });
    const sandboxes = parseSandboxLs(stdout);
    assert.equal(sandboxes.length, 2);
    assert.equal(sandboxes[0].name, '24114-natt-sync-selskap');
    assert.equal(sandboxes[0].agent, 'claude');
    assert.equal(sandboxes[0].status, 'running');
    assert.deepEqual(sandboxes[0].workspaces, ['/Users/alexalbu/repos/nho/ForeningshubV2/NHO.0474.Federationhub.Api']);
    assert.deepEqual(sandboxes[0].ports, []);
  });

  test('preserves a ports array when present', () => {
    const stdout = JSON.stringify({
      sandboxes: [
        {
          name: 'x',
          id: 'abc',
          agent: 'claude',
          status: 'running',
          workspaces: [],
          ports: [{ host_ip: '127.0.0.1', host_port: 8080, sandbox_port: 80, protocol: 'tcp' }],
        },
      ],
    });
    const sandboxes = parseSandboxLs(stdout);
    assert.deepEqual(sandboxes[0].ports, [{ host_ip: '127.0.0.1', host_port: 8080, sandbox_port: 80, protocol: 'tcp' }]);
  });

  test('tolerates a missing sandboxes key', () => {
    assert.deepEqual(parseSandboxLs('{}'), []);
  });

  test('throws a clean error on malformed JSON', () => {
    assert.throws(() => parseSandboxLs('not json'), /JSON|Unexpected/i);
  });
});

// formatPort's real home is public/shared/sandbox-commands.mjs (it has no
// Node-only APIs, so app.js can import the same implementation instead of
// keeping its own copy — see sandbox-commands.test.mjs for the exhaustive
// cases). This is just a smoke test that the re-export server code depends
// on stays wired up.
test('formatPort is re-exported from the shared module', () => {
  assert.equal(formatPort({ host_port: 8080, sandbox_port: 80, protocol: 'tcp' }), '8080->80/tcp');
});

describe('parseNetworkRules', () => {
  const sampleStdout = JSON.stringify({
    rules: [
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
      {
        id: 'default-fs-read-allow-all',
        name: 'default-fs-read-allow-all',
        policy_id: 'local-policy',
        scope: 'global',
        applies_to: 'all',
        resource_type: 'filesystem:read',
        decision: 'allow',
        resources: ['**'],
        origin: 'local',
        layer: 'local',
        status: 'active',
        editable: false,
      },
      {
        id: 'a8ddb581-491b-406d-9b3b-40642d09ac1d',
        name: 'kit:my-sandbox',
        policy_id: 'cd983560-276b-4a96-853c-93d0b07c2a4d',
        scope: 'sandbox:my-sandbox',
        applies_to: 'sandbox:my-sandbox',
        resource_type: 'network',
        decision: 'allow',
        resources: ['registry.example.com:443'],
        origin: 'scoped',
        layer: 'local',
        status: 'active',
        editable: false,
      },
      {
        id: 'user-added-rule-id',
        name: 'user-added-rule-id',
        policy_id: 'local-policy',
        scope: 'sandbox:my-sandbox',
        applies_to: 'sandbox:my-sandbox',
        resource_type: 'network',
        decision: 'deny',
        resources: ['ads.example.com'],
        origin: 'local',
        layer: 'local',
        status: 'active',
        editable: true,
      },
    ],
  });

  test('filters to network rules only', () => {
    const rules = parseNetworkRules(sampleStdout, 'my-sandbox');
    assert.ok(!rules.some((r) => r.id === 'default-fs-read-allow-all'));
  });

  test('marks a rule scoped to this sandbox as sandboxScoped', () => {
    const rules = parseNetworkRules(sampleStdout, 'my-sandbox');
    const rule = rules.find((r) => r.id === 'user-added-rule-id');
    assert.equal(rule.sandboxScoped, true);
  });

  test('marks a global rule as not sandboxScoped', () => {
    const rules = parseNetworkRules(sampleStdout, 'my-sandbox');
    const rule = rules.find((r) => r.id === 'default-ai-services');
    assert.equal(rule.sandboxScoped, false);
  });

  test('a sandbox-scoped, editable rule is removable', () => {
    const rules = parseNetworkRules(sampleStdout, 'my-sandbox');
    const rule = rules.find((r) => r.id === 'user-added-rule-id');
    assert.equal(rule.removable, true);
  });

  test('a sandbox-scoped but non-editable (kit) rule is not removable', () => {
    const rules = parseNetworkRules(sampleStdout, 'my-sandbox');
    const rule = rules.find((r) => r.id === 'a8ddb581-491b-406d-9b3b-40642d09ac1d');
    assert.equal(rule.removable, false);
  });

  test('a global rule is not removable regardless of editable', () => {
    const rules = parseNetworkRules(sampleStdout, 'my-sandbox');
    const rule = rules.find((r) => r.id === 'default-ai-services');
    assert.equal(rule.removable, false);
  });

  // Fail closed: a rule with no `editable` field at all must not be treated
  // as removable just because it isn't explicitly `false`.
  test('a sandbox-scoped rule with no editable field at all is not removable', () => {
    const stdout = JSON.stringify({
      rules: [
        {
          id: 'no-editable-field',
          name: 'no-editable-field',
          policy_id: 'local-policy',
          scope: 'sandbox:my-sandbox',
          applies_to: 'sandbox:my-sandbox',
          resource_type: 'network',
          decision: 'allow',
          resources: ['a.com'],
          origin: 'local',
          layer: 'local',
          status: 'active',
          // editable intentionally omitted
        },
      ],
    });
    const rules = parseNetworkRules(stdout, 'my-sandbox');
    assert.equal(rules[0].removable, false);
  });

  test('sorts sandbox-scoped rules before global rules', () => {
    const rules = parseNetworkRules(sampleStdout, 'my-sandbox');
    const firstGlobalIndex = rules.findIndex((r) => !r.sandboxScoped);
    const lastScopedIndex = rules.map((r) => r.sandboxScoped).lastIndexOf(true);
    assert.ok(lastScopedIndex < firstGlobalIndex);
  });
});
