import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { scanTree, completePath } from '../lib/scan.mjs';

function makeFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sbx-helper-scan-'));
  fs.mkdirSync(path.join(root, 'A', 'A1'), { recursive: true });
  fs.mkdirSync(path.join(root, 'A', '.git'), { recursive: true }); // stand-in repo marker
  fs.mkdirSync(path.join(root, 'B'), { recursive: true });
  fs.mkdirSync(path.join(root, 'B', 'node_modules', 'x'), { recursive: true });
  fs.mkdirSync(path.join(root, '.hidden'), { recursive: true });
  return root;
}

function makeCompletionFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sbx-helper-complete-'));
  fs.mkdirSync(path.join(root, 'AccessHubPortal'));
  fs.mkdirSync(path.join(root, 'AccessHubOther'));
  fs.mkdirSync(path.join(root, 'Consent-register'));
  fs.mkdirSync(path.join(root, 'node_modules'));
  fs.mkdirSync(path.join(root, '.hidden'));
  fs.writeFileSync(path.join(root, 'not-a-dir.txt'), '');
  return root;
}

test('scanTree respects maxDepth', () => {
  const root = makeFixture();
  const nodes = scanTree(root, 1, []);
  assert.ok(nodes.some((n) => n.path === path.join(root, 'A')));
  assert.ok(!nodes.some((n) => n.path === path.join(root, 'A', 'A1')));
});

test('scanTree skips ignoreFolders and dot-folders', () => {
  const root = makeFixture();
  const nodes = scanTree(root, 3, ['node_modules']);
  assert.ok(!nodes.some((n) => n.name === 'node_modules'));
  assert.ok(!nodes.some((n) => n.name === '.hidden'));
});

test('scanTree marks isGitRepo from a .git entry', () => {
  const root = makeFixture();
  const nodes = scanTree(root, 2, []);
  const a = nodes.find((n) => n.path === path.join(root, 'A'));
  const b = nodes.find((n) => n.path === path.join(root, 'B'));
  assert.equal(a.isGitRepo, true);
  assert.equal(b.isGitRepo, false);
});

test('scanTree marks an unreadable directory rather than throwing', () => {
  const root = makeFixture();
  const locked = path.join(root, 'locked');
  fs.mkdirSync(locked);
  fs.chmodSync(locked, 0o000);
  try {
    const nodes = scanTree(root, 2, []);
    const node = nodes.find((n) => n.path === locked);
    assert.ok(node, 'the unreadable directory itself should still be listed');
    assert.equal(node.unreadable, true);
  } finally {
    fs.chmodSync(locked, 0o755); // otherwise the temp-dir cleanup can't remove it
  }
});

test('completePath lists all subfolders for a trailing-slash prefix', () => {
  const root = makeCompletionFixture();
  const results = completePath(root + '/', []);
  assert.deepEqual(
    results.sort(),
    [
      path.join(root, 'AccessHubOther'),
      path.join(root, 'AccessHubPortal'),
      path.join(root, 'Consent-register'),
      path.join(root, 'node_modules'),
    ].sort(),
  );
});

test('completePath filters by a case-insensitive partial-name prefix', () => {
  const root = makeCompletionFixture();
  const results = completePath(path.join(root, 'access'), []);
  assert.deepEqual(
    results.sort(),
    [path.join(root, 'AccessHubOther'), path.join(root, 'AccessHubPortal')].sort(),
  );
});

test('completePath excludes ignoreFolders and dot-folders by default', () => {
  const root = makeCompletionFixture();
  const results = completePath(root + '/', ['node_modules']);
  assert.ok(!results.includes(path.join(root, 'node_modules')));
  assert.ok(!results.includes(path.join(root, '.hidden')));
});

test('completePath shows dot-folders once the partial itself starts with a dot', () => {
  const root = makeCompletionFixture();
  // Deliberately not path.join — that would normalize away the trailing ".".
  const results = completePath(`${root}/.`, []);
  assert.ok(results.includes(path.join(root, '.hidden')));
});

test('completePath excludes files, only directories', () => {
  const root = makeCompletionFixture();
  const results = completePath(root + '/', []);
  assert.ok(!results.includes(path.join(root, 'not-a-dir.txt')));
});

test('completePath returns [] for a non-absolute prefix', () => {
  assert.deepEqual(completePath('relative/path', []), []);
});

test('completePath returns [] for an unreadable or missing base directory', () => {
  assert.deepEqual(completePath('/this/does/not/exist/', []), []);
});
