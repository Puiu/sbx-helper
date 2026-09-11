// lib/terminal.mjs — server-only. Launches the assembled command in a new
// terminal window (macOS), and a pbcopy clipboard fallback.
//
// osascript's `write text "…"` needs AppleScript string escaping stacked on
// top of shell quoting — two nested layers, and the failure mode is a
// mangled or silently different command. Avoided instead of escaped through:
// the real (already-quoted) command is written to a temp .command script,
// and AppleScript only ever has to interpolate that script's own path,
// which this app generated itself and controls completely.

import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { formatCommand } from '../public/shared/command.mjs';

function run(cmd, args, input) {
  return new Promise((resolve) => {
    let proc;
    try {
      proc = spawn(cmd, args);
    } catch (err) {
      resolve({ ok: false, code: null, stderr: err.message });
      return;
    }
    let stderr = '';
    if (input !== undefined) {
      proc.stdin.write(input);
      proc.stdin.end();
    }
    proc.stderr?.on('data', (d) => { stderr += d; });
    proc.on('close', (code) => resolve({ ok: code === 0, code, stderr: stderr.trim() }));
    proc.on('error', (err) => resolve({ ok: false, code: null, stderr: err.message }));
  });
}

async function writeRunScript(args) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'sbx-helper-'));
  const scriptPath = path.join(dir, 'run.command');
  const content = `#!/bin/sh\nexec ${formatCommand(args)}\n`;
  await fs.writeFile(scriptPath, content, { mode: 0o700 });
  return scriptPath;
}

// Belt-and-braces: the interpolated value is our own mkdtemp path (never
// contains a quote in practice), but escape it for the AppleScript string
// literal anyway rather than assume that.
function escapeAppleScriptString(s) {
  return s.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

/**
 * Opens a new terminal window running `args` (already-built sbx argv).
 * Tries, in order: a new iTerm2 window via AppleScript, `open -a iTerm`,
 * `open -a Terminal`. Returns { ok, method } or { ok: false, error }.
 */
export async function launchInTerminal(args) {
  const scriptPath = await writeRunScript(args);
  const escaped = escapeAppleScriptString(scriptPath);
  const appleScript = `tell application "iTerm"
  create window with default profile
  tell current session of current window
    write text "source \\"${escaped}\\""
  end tell
end tell`;

  const viaAppleScript = await run('osascript', ['-e', appleScript]);
  if (viaAppleScript.ok) return { ok: true, method: 'iterm-applescript' };

  const viaOpenIterm = await run('open', ['-a', 'iTerm', scriptPath]);
  if (viaOpenIterm.ok) return { ok: true, method: 'iterm-open' };

  const viaOpenTerminal = await run('open', ['-a', 'Terminal', scriptPath]);
  if (viaOpenTerminal.ok) return { ok: true, method: 'terminal-open' };

  return {
    ok: false,
    error: viaAppleScript.stderr || viaOpenTerminal.stderr || 'Could not open a terminal window.',
  };
}

export async function copyToClipboard(text) {
  const result = await run('pbcopy', [], text);
  return { ok: result.ok, error: result.ok ? null : result.stderr };
}

/** Opens `dirPath` in a new Finder window. */
export async function revealInFinder(dirPath) {
  const result = await run('open', [dirPath]);
  return { ok: result.ok, error: result.ok ? null : result.stderr };
}
