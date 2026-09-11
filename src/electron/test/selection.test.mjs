import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { isAncestor, findCoveringPath, findAnyConflict, resolvePrimary } from '../public/shared/selection.mjs';

describe('isAncestor', () => {
  test('true for a direct parent/child pair', () => {
    assert.ok(isAncestor('/root/A', '/root/A/B'));
  });
  test('false for a same-prefix sibling', () => {
    assert.ok(!isAncestor('/root/A', '/root/AB'));
  });
  test('false for a path compared to itself', () => {
    assert.ok(!isAncestor('/root/A', '/root/A'));
  });
});

describe('findCoveringPath', () => {
  test('flags a descendant of an already-selected folder', () => {
    assert.equal(findCoveringPath('/root/A/B', ['/root/A']), '/root/A');
  });
  test('flags an ancestor of an already-selected folder', () => {
    assert.equal(findCoveringPath('/root/A', ['/root/A/B']), '/root/A/B');
  });
  test('returns null when there is no overlap', () => {
    assert.equal(findCoveringPath('/root/C', ['/root/A', '/root/B']), null);
  });
});

describe('findAnyConflict', () => {
  test('catches a nested pair anywhere in the list', () => {
    assert.ok(findAnyConflict(['/root/A', '/root/C', '/root/A/B']));
  });
  test('returns null for a fully disjoint list', () => {
    assert.equal(findAnyConflict(['/root/A', '/root/B', '/root/C']), null);
  });
});

describe('resolvePrimary', () => {
  test('defaults to the ordinal-first editable path', () => {
    assert.equal(resolvePrimary(['/root/B', '/root/A'], null), '/root/A');
  });
  test('honors an explicit override that is still editable', () => {
    assert.equal(resolvePrimary(['/root/B', '/root/A'], '/root/B'), '/root/B');
  });
  test('ignores an override no longer in the editable set', () => {
    assert.equal(resolvePrimary(['/root/B', '/root/A'], '/root/Z'), '/root/A');
  });
  test('returns null when nothing is editable', () => {
    assert.equal(resolvePrimary([], '/root/A'), null);
  });
});
