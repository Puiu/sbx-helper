import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseTemplateLs } from '../lib/templates.mjs';

test('parseTemplateLs extracts repo:tag pairs and skips the header', () => {
  const sample =
    'REPOSITORY                              TAG                  IMAGE ID       FLAVOR               CREATED\n' +
    'docker.io/library/claude-sbx-dotnet10   v2                   e7df4a3fd671   claude-code          About an hour ago\n' +
    'docker.io/library/claude-sbx-dotnet10   v1                   b9ec0cd15117   claude-code          About an hour ago\n';
  assert.deepEqual(parseTemplateLs(sample), [
    'docker.io/library/claude-sbx-dotnet10:v2',
    'docker.io/library/claude-sbx-dotnet10:v1',
  ]);
});

test('parseTemplateLs handles empty output', () => {
  assert.deepEqual(parseTemplateLs(''), []);
});

test('parseTemplateLs de-duplicates identical repo:tag pairs', () => {
  const sample =
    'REPOSITORY   TAG   IMAGE ID   FLAVOR   CREATED\n' +
    'repo/a       v1    abc123     flavor   now\n' +
    'repo/a       v1    def456     flavor   now\n';
  assert.deepEqual(parseTemplateLs(sample), ['repo/a:v1']);
});
