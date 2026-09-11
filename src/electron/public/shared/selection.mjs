// public/shared/selection.mjs
//
// Pure path-prefix logic for the "no nested mounts" rule, and for picking
// the primary workspace. No Node-only APIs — this file is served to the
// browser as-is (import from '/shared/selection.mjs') and also imported
// directly by the server.

function normalize(p) {
  return p.endsWith('/') && p.length > 1 ? p.slice(0, -1) : p;
}

/** Is `ancestor` a strict ancestor directory of `of`? */
export function isAncestor(ancestor, of) {
  const a = normalize(ancestor);
  const b = normalize(of);
  return a !== b && b.startsWith(a + '/');
}

/**
 * Returns the selected path that makes `candidate` invalid to also select
 * (because one would be nested inside the other), or null if `candidate`
 * is free to select. `selectedPaths` should not include `candidate` itself.
 */
export function findCoveringPath(candidate, selectedPaths) {
  for (const s of selectedPaths) {
    if (s === candidate) continue;
    if (isAncestor(s, candidate) || isAncestor(candidate, s)) return s;
  }
  return null;
}

/**
 * First conflicting pair found in an arbitrary path list, or null.
 * Used as a server-side backstop in case a client ever posts a bad selection.
 */
export function findAnyConflict(paths) {
  for (let i = 0; i < paths.length; i++) {
    for (let j = i + 1; j < paths.length; j++) {
      if (isAncestor(paths[i], paths[j])) return `${paths[j]} is inside ${paths[i]}`;
      if (isAncestor(paths[j], paths[i])) return `${paths[i]} is inside ${paths[j]}`;
    }
  }
  return null;
}

/**
 * The primary workspace: an explicit override if it's still editable, else
 * the ordinal-first editable path (a stable, order-independent default).
 */
export function resolvePrimary(editablePaths, explicitPrimary) {
  if (!editablePaths || editablePaths.length === 0) return null;
  if (explicitPrimary && editablePaths.includes(explicitPrimary)) return explicitPrimary;
  return [...editablePaths].sort()[0];
}
