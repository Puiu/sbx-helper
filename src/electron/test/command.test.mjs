import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { quotePosix, formatCommand, buildArgs, buildCommand } from '../public/shared/command.mjs';

describe('quotePosix', () => {
  test('leaves a safe path unquoted', () => {
    assert.equal(quotePosix('/path/to/NHO.AccessHub.Web'), '/path/to/NHO.AccessHub.Web');
  });

  test('quotes a path containing a space', () => {
    assert.equal(quotePosix('/path/with space'), "'/path/with space'");
  });

  test('escapes an embedded single quote', () => {
    const q = quotePosix("/it's/here");
    assert.ok(q.startsWith("'") && q.endsWith("'"));
    assert.ok(q.includes("'\\''"));
  });
});

describe('buildCommand', () => {
  test('reproduces the target example exactly', () => {
    const { display } = buildCommand({
      agent: 'claude',
      template: 'claude-sbx-dotnet10:v2',
      name: null,
      clone: false,
      editable: ['/path/to/NHO.0476.ConsentRegister.Web'],
      readOnly: ['/path/to/NHO.AccessHub.Web'],
      primary: null,
    });
    assert.equal(
      display,
      'sbx run --template claude-sbx-dotnet10:v2 claude /path/to/NHO.0476.ConsentRegister.Web /path/to/NHO.AccessHub.Web:ro',
    );
  });

  test('supports multiple editable and multiple read-only folders, primary first', () => {
    const { args } = buildCommand({
      agent: 'claude',
      template: 'tpl',
      name: null,
      clone: false,
      editable: ['/root/B', '/root/A'],
      readOnly: ['/root/D', '/root/C'],
      primary: '/root/A',
    });
    assert.deepEqual(args, [
      'sbx', 'run', '--template', 'tpl',
      'claude', '/root/A', '/root/B', '/root/C:ro', '/root/D:ro',
    ]);
  });

  test('places --name and --clone before the agent', () => {
    const { display } = buildCommand({
      agent: 'claude',
      template: 'tpl:v1',
      name: 'my-sandbox',
      clone: true,
      editable: ['/root/A'],
      readOnly: [],
      primary: null,
    });
    assert.equal(display, 'sbx run --template tpl:v1 --name my-sandbox --clone claude /root/A');
  });

  test('the :ro suffix stays inside the quotes for a spaced path', () => {
    const { display } = buildCommand({
      agent: 'claude',
      template: 'tpl',
      name: null,
      clone: false,
      editable: ['/root/A'],
      readOnly: ['/path/with space'],
      primary: null,
    });
    assert.ok(display.includes("'/path/with space:ro'"));
  });

  test('an unpromoted, no-longer-editable primary falls back to the default', () => {
    const { args } = buildCommand({
      agent: 'claude',
      template: 'tpl',
      name: null,
      clone: false,
      editable: ['/root/B', '/root/A'],
      readOnly: [],
      primary: '/root/Z', // not in editable
    });
    assert.equal(args[args.indexOf('claude') + 1], '/root/A');
  });

  test('throws when no editable workspace is selected', () => {
    assert.throws(() => buildArgs({ agent: 'claude', template: 'tpl', editable: [], readOnly: [] }));
  });
});
