// public/shared/command.mjs
//
// `sbx run` argument assembly and POSIX quoting. No Node-only APIs — this
// file is served to the browser as-is (for the live command preview) and
// also imported directly by the server (to build the real argv for spawn).
// One implementation, so what you see previewed is exactly what runs.

import { resolvePrimary } from './selection.mjs';

const SAFE_UNQUOTED = /^[A-Za-z0-9._/:-]+$/;

/** Quotes a single shell argument for POSIX (macOS/Linux) shells. */
export function quotePosix(arg) {
  if (SAFE_UNQUOTED.test(arg)) return arg;
  return "'" + arg.replace(/'/g, "'\\''") + "'";
}

/** Joins already-ordered argv into a single display/paste-able command string. */
export function formatCommand(args) {
  return args.map(quotePosix).join(' ');
}

/** Primary first, then the rest of the editable paths in a stable order. */
export function orderedWorkspaces(primary, editable) {
  const rest = editable.filter((p) => p !== primary).sort();
  return [primary, ...rest];
}

/**
 * Builds the `sbx run` argv:
 *   sbx run --template <tpl> [--name <n>] [--clone] <agent> <primary> [<other editable>…] [<ro>:ro …]
 *
 * Throws if `editable` is empty — callers must guard for that (there is
 * nothing sensible to run without at least one editable workspace).
 */
export function buildArgs({ agent, template, name, clone, editable, readOnly, primary }) {
  if (!editable || editable.length === 0) {
    throw new Error('At least one editable workspace is required.');
  }
  const actualPrimary = resolvePrimary(editable, primary);
  const ordered = orderedWorkspaces(actualPrimary, editable);

  const args = ['sbx', 'run', '--template', template];
  if (name && String(name).trim()) args.push('--name', String(name).trim());
  if (clone) args.push('--clone');
  args.push(agent);
  args.push(...ordered);
  args.push(...[...(readOnly || [])].sort().map((p) => p + ':ro'));
  return args;
}

/** Convenience wrapper returning both the argv and its display string. */
export function buildCommand(selection) {
  const args = buildArgs(selection);
  return { args, display: formatCommand(args) };
}
