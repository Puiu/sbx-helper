// lib/sandboxes.mjs — server-only. `sbx ls`/`sbx policy ls` invocation +
// parsing, and a generic spawn wrapper for the mutating sbx subcommands
// (stop, rm, policy allow/deny/rm) used by the Sandboxes tab.

import { spawn } from 'node:child_process';

// formatPort has no Node-only APIs, so its one true home is public/shared/
// (app.js imports the same implementation for the sandbox list/detail view,
// instead of keeping its own copy that could drift). Re-exported here so
// existing server-side imports of `formatPort` from this file keep working.
export { formatPort } from '../public/shared/sandbox-commands.mjs';

/** Parses `sbx ls --json` stdout into a flat sandbox list. Throws on malformed JSON. */
export function parseSandboxLs(stdout) {
  const parsed = JSON.parse(stdout);
  const sandboxes = Array.isArray(parsed.sandboxes) ? parsed.sandboxes : [];
  return sandboxes.map((s) => ({
    name: s.name,
    id: s.id,
    agent: s.agent,
    status: s.status,
    workspaces: Array.isArray(s.workspaces) ? s.workspaces : [],
    ports: Array.isArray(s.ports) ? s.ports : [],
  }));
}

/**
 * Parses `sbx policy ls <name> --json` stdout into network-only rules,
 * annotated with whether each rule is scoped to `sandboxName` and whether
 * it's safe to offer removal for (sandbox-scoped AND editable). Sandbox-
 * scoped rules sort first so the sandbox's own rules are what you see.
 */
export function parseNetworkRules(stdout, sandboxName) {
  const parsed = JSON.parse(stdout);
  const rules = Array.isArray(parsed.rules) ? parsed.rules : [];
  const scopeTag = `sandbox:${sandboxName}`;
  return rules
    .filter((r) => r.resource_type === 'network')
    .map((r) => {
      const sandboxScoped = r.scope === scopeTag;
      return {
        id: r.id,
        name: r.name,
        decision: r.decision,
        resources: Array.isArray(r.resources) ? r.resources : [],
        scope: r.scope,
        origin: r.origin,
        status: r.status,
        sandboxScoped,
        // Fail closed: only an explicit editable:true is removable — a rule
        // missing the field entirely must not be treated as editable just
        // because it isn't explicitly false.
        removable: sandboxScoped && r.editable === true,
      };
    })
    .sort((a, b) => Number(b.sandboxScoped) - Number(a.sandboxScoped));
}

const MAX_OUTPUT_BYTES = 1_000_000; // per stream — bounds a runaway/wedged child's buffers

/** Runs `sbx <args>` and captures stdout/stderr. Never throws. */
export function runSbx(args, { timeoutMs = 10000 } = {}) {
  return new Promise((resolve) => {
    let settled = false;
    // Declared (as `undefined`) before anything that could call finish(), so
    // a synchronous throw from spawn() below can never hit this in its
    // temporal dead zone — clearTimeout(undefined) is a safe no-op.
    let timer;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };

    let proc;
    try {
      proc = spawn('sbx', args);
    } catch (err) {
      return finish({ ok: false, code: null, stdout: '', stderr: err.message });
    }

    let stdout = '';
    let stderr = '';
    const append = (existing, chunk) => (existing.length >= MAX_OUTPUT_BYTES ? existing : existing + chunk);

    timer = setTimeout(() => {
      try {
        proc.kill('SIGTERM');
      } catch {
        /* already gone */
      }
      // Escalate if the process ignores SIGTERM. Independent of settling the
      // promise above — we've already given up waiting, but the child
      // should still not be left running indefinitely. unref() so this
      // follow-up timer alone can't keep the process (or a test run) alive.
      setTimeout(() => {
        try {
          proc.kill('SIGKILL');
        } catch {
          /* already exited */
        }
      }, 2000).unref();
      finish({ ok: false, code: null, stdout, stderr: stderr || 'Timed out waiting for sbx.' });
    }, timeoutMs);

    proc.stdout.on('data', (d) => { stdout = append(stdout, d); });
    proc.stderr.on('data', (d) => { stderr = append(stderr, d); });
    proc.on('error', (err) => finish({ ok: false, code: null, stdout, stderr: err.message }));
    proc.on('close', (code) => finish({ ok: code === 0, code, stdout, stderr: stderr.trim() }));
  });
}

/** Lists sandboxes via `sbx ls --json`. Never throws — reports failure in the result. */
export async function listSandboxes({ timeoutMs = 10000 } = {}) {
  const result = await runSbx(['ls', '--json'], { timeoutMs });
  if (!result.ok) return { ok: false, sandboxes: [], error: result.stderr || 'sbx ls failed.' };
  try {
    return { ok: true, sandboxes: parseSandboxLs(result.stdout), error: null };
  } catch (err) {
    return { ok: false, sandboxes: [], error: `Could not parse sbx ls output: ${err.message}` };
  }
}

/** Lists a sandbox's network policy rules via `sbx policy ls <name> --json`. Never throws. */
export async function listNetworkRules(name, { timeoutMs = 10000 } = {}) {
  const result = await runSbx(['policy', 'ls', name, '--json'], { timeoutMs });
  if (!result.ok) return { ok: false, rules: [], error: result.stderr || 'sbx policy ls failed.' };
  try {
    return { ok: true, rules: parseNetworkRules(result.stdout, name), error: null };
  } catch (err) {
    return { ok: false, rules: [], error: `Could not parse sbx policy ls output: ${err.message}` };
  }
}
