// lib/scan.mjs — server-only. Eager directory-tree scan.
//
// Measured on the real ~/repos/nho checkout: 316 directories at depth 3 in
// ~15ms (677 at depth 4 in ~53ms). Cheap enough to scan the whole tree on
// every request rather than lazily expanding nodes — the frontend gets one
// flat array and filters it client-side.

import fs from 'node:fs';
import path from 'node:path';

/**
 * Returns a flat, depth-first pre-order array of
 * { path, name, depth, isGitRepo, unreadable }. The root itself is the
 * first element (depth 0) and is always included, even if unreadable.
 */
export function scanTree(rootPath, maxDepth, ignoreFolders) {
  const ignore = new Set(ignoreFolders || []);
  const nodes = [];

  function visit(dirPath, depth) {
    let entries = [];
    let unreadable = false;
    try {
      entries = fs.readdirSync(dirPath, { withFileTypes: true });
    } catch {
      unreadable = true;
    }

    const isGitRepo = fs.existsSync(path.join(dirPath, '.git'));
    nodes.push({
      path: dirPath,
      name: depth === 0 ? dirPath : path.basename(dirPath),
      depth,
      isGitRepo,
      unreadable,
    });

    if (unreadable || depth >= maxDepth) return;

    const dirs = entries
      .filter((e) => e.isDirectory())
      .map((e) => e.name)
      .filter((name) => !name.startsWith('.') && !ignore.has(name))
      .sort((a, b) => a.localeCompare(b));

    for (const name of dirs) visit(path.join(dirPath, name), depth + 1);
  }

  visit(rootPath, 0);
  return nodes;
}

/**
 * Path autocomplete for the "change root" dialog. Splits `prefix` at its
 * last "/" into a base directory and a partial name, and returns up to 25
 * absolute paths of that directory's subfolders whose name starts with the
 * partial (case-insensitive). Dot-folders are skipped unless the partial
 * itself starts with ".", matching how you'd expect to reach them by typing.
 * Returns [] for a non-absolute prefix or an unreadable/missing base
 * directory — there is nothing wrong to report, the user is mid-typing.
 */
export function completePath(prefix, ignoreFolders) {
  if (typeof prefix !== 'string' || !prefix.startsWith('/')) return [];
  const ignore = new Set(ignoreFolders || []);

  const endsWithSlash = prefix.endsWith('/');
  const baseDir = endsWithSlash ? prefix.slice(0, -1) || '/' : path.dirname(prefix);
  const partial = endsWithSlash ? '' : path.basename(prefix);
  const partialLower = partial.toLowerCase();
  const showDotDirs = partial.startsWith('.');

  let entries;
  try {
    entries = fs.readdirSync(baseDir, { withFileTypes: true });
  } catch {
    return [];
  }

  return entries
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .filter((name) => (showDotDirs || !name.startsWith('.')) && !ignore.has(name))
    .filter((name) => name.toLowerCase().startsWith(partialLower))
    .sort((a, b) => a.localeCompare(b))
    .slice(0, 25)
    .map((name) => path.join(baseDir, name));
}
