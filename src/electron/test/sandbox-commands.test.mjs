import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  defaultAgentArgs,
  tokenizeArgs,
  validateAgentArgs,
  buildRunExistingArgs,
  buildStopArgs,
  buildRemoveArgs,
  buildPolicyAddArgs,
  buildPolicyRemoveArgs,
  isValidNetworkResource,
  parseResourceList,
  formatPort,
  MAX_AGENT_ARG_TOKENS,
  MAX_AGENT_ARG_LEN,
  MAX_RESOURCES_PER_REQUEST,
} from '../public/shared/sandbox-commands.mjs';
import { formatCommand } from '../public/shared/command.mjs';

describe('defaultAgentArgs', () => {
  test('claude defaults to --model opusplan', () => {
    assert.deepEqual(defaultAgentArgs('claude'), ['--model', 'opusplan']);
  });

  test('opencode has no default args', () => {
    assert.deepEqual(defaultAgentArgs('opencode'), []);
  });

  test('an unknown agent has no default args', () => {
    assert.deepEqual(defaultAgentArgs('some-future-agent'), []);
  });
});

describe('tokenizeArgs', () => {
  test('splits a simple space-separated string', () => {
    assert.deepEqual(tokenizeArgs('--model opusplan'), ['--model', 'opusplan']);
  });

  test('honors single-quoted values', () => {
    assert.deepEqual(tokenizeArgs("--message 'hello world'"), ['--message', 'hello world']);
  });

  test('honors double-quoted values', () => {
    assert.deepEqual(tokenizeArgs('--message "hello world"'), ['--message', 'hello world']);
  });

  test('empty string tokenizes to an empty array', () => {
    assert.deepEqual(tokenizeArgs(''), []);
  });

  test('whitespace-only string tokenizes to an empty array', () => {
    assert.deepEqual(tokenizeArgs('   \t  '), []);
  });

  test('collapses repeated whitespace between tokens', () => {
    assert.deepEqual(tokenizeArgs('--model    opusplan'), ['--model', 'opusplan']);
  });

  test('round-trips through formatCommand for a simple case', () => {
    const argv = tokenizeArgs('--model opusplan');
    assert.deepEqual(tokenizeArgs(formatCommand(argv)), argv);
  });

  test('round-trips through formatCommand when a value has a space', () => {
    const argv = tokenizeArgs("--message 'hello world'");
    assert.deepEqual(tokenizeArgs(formatCommand(argv)), argv);
  });

  // Regression: quotePosix escapes an embedded single quote as the POSIX
  // '\'' idiom (close quote, escaped literal quote, reopen quote) — see
  // command.mjs. A tokenizer that only understands whole-token '...'/"..."
  // quoting can't parse that back into one token; it did earlier at token
  // splits, silently corrupting a persisted args string on every reload.
  test('round-trips through formatCommand when a value has an embedded single quote', () => {
    const argv = ['--append-system-prompt', "don't stop"];
    const display = formatCommand(argv);
    assert.equal(display, "--append-system-prompt 'don'\\''t stop'");
    assert.deepEqual(tokenizeArgs(display), argv);
  });

  test('honors a backslash-escaped space outside quotes', () => {
    assert.deepEqual(tokenizeArgs('a\\ b'), ['a b']);
  });

  test('concatenates adjacent quoted and unquoted runs into one token', () => {
    assert.deepEqual(tokenizeArgs('a"b"c'), ['abc']);
  });

  test('an unterminated quote does not throw — it just consumes to end of input', () => {
    assert.deepEqual(tokenizeArgs("--flag 'unterminated"), ['--flag', 'unterminated']);
  });
});

describe('validateAgentArgs', () => {
  test('null for a normal args list', () => {
    assert.equal(validateAgentArgs(['--model', 'opusplan']), null);
  });

  test('null for an empty list', () => {
    assert.equal(validateAgentArgs([]), null);
  });

  test('rejects more than MAX_AGENT_ARG_TOKENS tokens', () => {
    const tooMany = Array.from({ length: MAX_AGENT_ARG_TOKENS + 1 }, (_, i) => `t${i}`);
    assert.match(validateAgentArgs(tooMany), /too many/i);
  });

  test('accepts exactly MAX_AGENT_ARG_TOKENS tokens', () => {
    const justRight = Array.from({ length: MAX_AGENT_ARG_TOKENS }, (_, i) => `t${i}`);
    assert.equal(validateAgentArgs(justRight), null);
  });

  test('rejects a token longer than MAX_AGENT_ARG_LEN', () => {
    assert.match(validateAgentArgs(['a'.repeat(MAX_AGENT_ARG_LEN + 1)]), /too long/i);
  });

  test('rejects a non-string element', () => {
    assert.ok(validateAgentArgs(['ok', 42]));
  });

  test('rejects an empty-string element', () => {
    assert.ok(validateAgentArgs(['ok', '']));
  });

  test('rejects a newline in a token', () => {
    assert.ok(validateAgentArgs(['a\nb']));
  });

  test('rejects a NUL byte in a token', () => {
    assert.ok(validateAgentArgs(['a\0b']));
  });

  test('rejects an ESC control character in a token — narrower "no \\n\\r\\0 only" checks used to miss this', () => {
    assert.ok(validateAgentArgs(['a\x1bb']));
  });

  test('rejects a non-array', () => {
    assert.ok(validateAgentArgs('--model opusplan'));
  });
});

describe('buildRunExistingArgs', () => {
  test('includes the -- separator and agent args when args are given', () => {
    const args = buildRunExistingArgs({ name: 'my-sandbox', agentArgs: ['--model', 'opusplan'] });
    assert.deepEqual(args, ['sbx', 'run', '--name', 'my-sandbox', '--', '--model', 'opusplan']);
  });

  test('omits the -- separator entirely when there are no agent args', () => {
    const args = buildRunExistingArgs({ name: 'my-sandbox', agentArgs: [] });
    assert.deepEqual(args, ['sbx', 'run', '--name', 'my-sandbox']);
  });

  test('throws when name is missing', () => {
    assert.throws(() => buildRunExistingArgs({ name: '', agentArgs: [] }));
  });

  test('throws when agentArgs fails structural validation, e.g. a control character', () => {
    assert.throws(() => buildRunExistingArgs({ name: 'x', agentArgs: ['a\nb'] }));
  });

  test('throws when agentArgs has too many tokens', () => {
    const tooMany = Array.from({ length: MAX_AGENT_ARG_TOKENS + 1 }, (_, i) => `t${i}`);
    assert.throws(() => buildRunExistingArgs({ name: 'x', agentArgs: tooMany }));
  });
});

describe('buildStopArgs', () => {
  test('builds sbx stop <name>', () => {
    assert.deepEqual(buildStopArgs('my-sandbox'), ['sbx', 'stop', 'my-sandbox']);
  });

  test('throws when name is missing', () => {
    assert.throws(() => buildStopArgs(''));
  });
});

describe('buildRemoveArgs', () => {
  test('builds sbx rm --force <name>', () => {
    assert.deepEqual(buildRemoveArgs('my-sandbox'), ['sbx', 'rm', '--force', 'my-sandbox']);
  });

  test('throws when name is missing', () => {
    assert.throws(() => buildRemoveArgs(''));
  });
});

describe('buildPolicyAddArgs', () => {
  test('joins multiple resources into one comma-separated argv token, allow', () => {
    const args = buildPolicyAddArgs({ name: 'x', decision: 'allow', resources: ['a.com', '*.b.com'] });
    assert.deepEqual(args, ['sbx', 'policy', 'allow', 'network', '--sandbox', 'x', 'a.com,*.b.com']);
  });

  test('builds a deny rule', () => {
    const args = buildPolicyAddArgs({ name: 'x', decision: 'deny', resources: ['ads.example.com'] });
    assert.deepEqual(args, ['sbx', 'policy', 'deny', 'network', '--sandbox', 'x', 'ads.example.com']);
  });

  test('throws on an empty resource list', () => {
    assert.throws(() => buildPolicyAddArgs({ name: 'x', decision: 'allow', resources: [] }));
  });

  test('throws on a decision that is neither allow nor deny', () => {
    assert.throws(() => buildPolicyAddArgs({ name: 'x', decision: 'maybe', resources: ['a.com'] }));
  });

  test('throws when name is missing', () => {
    assert.throws(() => buildPolicyAddArgs({ name: '', decision: 'allow', resources: ['a.com'] }));
  });
});

describe('buildPolicyRemoveArgs', () => {
  test('removes by rule id', () => {
    const args = buildPolicyRemoveArgs({ name: 'x', ruleId: 'abc-123' });
    assert.deepEqual(args, ['sbx', 'policy', 'rm', 'network', '--sandbox', 'x', '--id', 'abc-123']);
  });

  test('removes by resource', () => {
    const args = buildPolicyRemoveArgs({ name: 'x', resource: 'a.com' });
    assert.deepEqual(args, ['sbx', 'policy', 'rm', 'network', '--sandbox', 'x', '--resource', 'a.com']);
  });

  test('throws when neither ruleId nor resource is given', () => {
    assert.throws(() => buildPolicyRemoveArgs({ name: 'x' }));
  });

  test('throws when name is missing', () => {
    assert.throws(() => buildPolicyRemoveArgs({ name: '', ruleId: 'abc-123' }));
  });
});

describe('isValidNetworkResource', () => {
  const accept = [
    'example.com', '*.example.com', '**.example.com', '**', 'example.com:443', 'api.example.com:8080',
    'crl*.digicert.com:80', // real sbx daemon data: a wildcard embedded mid-label, not just leading
  ];
  const reject = [
    'a b', 'a;b', '--flag', '', '   ', 'a\nb', 'a\tb',
    'example.com:0', 'example.com:99999', // out of the valid TCP port range
  ];

  for (const s of accept) {
    test(`accepts ${JSON.stringify(s)}`, () => {
      assert.equal(isValidNetworkResource(s), true);
    });
  }
  for (const s of reject) {
    test(`rejects ${JSON.stringify(s)}`, () => {
      assert.equal(isValidNetworkResource(s), false);
    });
  }

  test('accepts the port range boundaries 1 and 65535', () => {
    assert.equal(isValidNetworkResource('example.com:1'), true);
    assert.equal(isValidNetworkResource('example.com:65535'), true);
  });
});

describe('parseResourceList', () => {
  test('splits on commas', () => {
    assert.deepEqual(parseResourceList('a.com,b.com'), ['a.com', 'b.com']);
  });

  test('splits on whitespace', () => {
    assert.deepEqual(parseResourceList('a.com b.com'), ['a.com', 'b.com']);
  });

  test('trims and drops empty entries', () => {
    assert.deepEqual(parseResourceList(' a.com , , b.com '), ['a.com', 'b.com']);
  });

  test('empty string yields an empty array', () => {
    assert.deepEqual(parseResourceList(''), []);
  });
});

describe('formatPort', () => {
  test('formats a published port with an explicit host IP', () => {
    assert.equal(
      formatPort({ host_ip: '127.0.0.1', host_port: 8080, sandbox_port: 80, protocol: 'tcp' }),
      '127.0.0.1:8080->80/tcp',
    );
  });

  test('formats a published port without a host IP', () => {
    assert.equal(formatPort({ host_port: 8080, sandbox_port: 80, protocol: 'tcp' }), '8080->80/tcp');
  });
});

test('MAX_RESOURCES_PER_REQUEST is a positive number both server and client can share', () => {
  assert.equal(typeof MAX_RESOURCES_PER_REQUEST, 'number');
  assert.ok(MAX_RESOURCES_PER_REQUEST > 0);
});
