// lib/templates.mjs — server-only. `sbx template ls` invocation + parsing.

import { spawn } from 'node:child_process';

/** Parses `sbx template ls` table output into "repo:tag" strings. */
export function parseTemplateLs(stdout) {
  const lines = stdout.split('\n').map((l) => l.trim()).filter(Boolean);
  const result = [];
  for (const line of lines) {
    if (/^REPOSITORY\b/i.test(line)) continue;
    const cols = line.split(/\s{2,}/);
    if (cols.length >= 2 && cols[0] && cols[1]) result.push(`${cols[0]}:${cols[1]}`);
  }
  return [...new Set(result)];
}

/** Returns [] (never throws) if `sbx` isn't on PATH or the call fails/times out. */
export function listTemplates({ timeoutMs = 5000 } = {}) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };

    let proc;
    try {
      proc = spawn('sbx', ['template', 'ls']);
    } catch {
      return finish([]);
    }

    let stdout = '';
    const timer = setTimeout(() => {
      try { proc.kill(); } catch { /* already gone */ }
      finish([]);
    }, timeoutMs);

    proc.stdout.on('data', (d) => { stdout += d; });
    proc.on('error', () => finish([]));
    proc.on('close', (code) => finish(code === 0 ? parseTemplateLs(stdout) : []));
  });
}
