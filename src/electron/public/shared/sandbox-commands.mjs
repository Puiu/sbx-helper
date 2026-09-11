// public/shared/sandbox-commands.mjs
//
// argv assembly for the Sandboxes tab: run (re-attach), stop, rm, and
// per-sandbox network policy allow/deny/rm. No Node-only APIs — this file is
// served to the browser as-is (for the live command preview) and also
// imported directly by the server (to build the real argv for spawn). One
// implementation, so what you see previewed is exactly what runs. See
// public/shared/command.mjs for the sibling module covering `sbx run`
// (create) argv.

/** Per-agent default trailing args for "Run" on an existing sandbox. */
export const AGENT_DEFAULT_ARGS = {
  claude: ['--model', 'opusplan'],
};

/** Default agent-args tail for `agent`, or [] if it has none. */
export function defaultAgentArgs(agent) {
  return AGENT_DEFAULT_ARGS[agent] ? [...AGENT_DEFAULT_ARGS[agent]] : [];
}

/**
 * Splits free-text agent args into argv tokens. A real (if minimal) POSIX
 * word-splitter, not just "whole-token '...'/\"...\" quoting" — it has to
 * be, to round-trip with quotePosix() in command.mjs, which escapes an
 * embedded single quote as the `'\''` idiom: close the quote, emit a
 * backslash-escaped literal quote outside of any quoting, reopen the quote.
 * Adjacent quoted and unquoted runs with no separating whitespace
 * concatenate into one token, exactly as a POSIX shell would join them —
 * that's what makes the live preview truthful to what will actually run.
 * Never throws, even on an unterminated quote (the rest of the string is
 * just consumed as a literal token) — this is a best-effort tokenizer for a
 * live preview, not a strict parser.
 */
export function tokenizeArgs(text) {
  const tokens = [];
  if (!text) return tokens;

  let i = 0;
  const n = text.length;
  let current = '';
  let inToken = false;

  const pushCurrent = () => {
    if (inToken) tokens.push(current);
    current = '';
    inToken = false;
  };

  while (i < n) {
    const ch = text[i];

    if (/\s/.test(ch)) {
      pushCurrent();
      i++;
      continue;
    }

    if (ch === "'") {
      inToken = true;
      i++;
      while (i < n && text[i] !== "'") {
        current += text[i];
        i++;
      }
      i++; // skip the closing quote (or run past the end, for an unterminated one)
      continue;
    }

    if (ch === '"') {
      inToken = true;
      i++;
      while (i < n && text[i] !== '"') {
        if (text[i] === '\\' && i + 1 < n && (text[i + 1] === '"' || text[i + 1] === '\\')) {
          current += text[i + 1];
          i += 2;
        } else {
          current += text[i];
          i++;
        }
      }
      i++;
      continue;
    }

    if (ch === '\\') {
      inToken = true;
      i++;
      if (i < n) {
        current += text[i];
        i++;
      }
      continue;
    }

    inToken = true;
    current += ch;
    i++;
  }
  pushCurrent();
  return tokens;
}

export const MAX_AGENT_ARG_TOKENS = 32;
export const MAX_AGENT_ARG_LEN = 256;

/**
 * Structural validation only — an arbitrary agent flag is the feature, not
 * something to allowlist by content. Bounds size and rules out control
 * characters (a newline inside a token would make the <pre> preview lie
 * about what runs). Returns null when acceptable, else a human-readable
 * reason.
 */
export function validateAgentArgs(tokens) {
  if (!Array.isArray(tokens)) return 'Agent arguments must be a list.';
  if (tokens.length > MAX_AGENT_ARG_TOKENS) return `Too many agent-argument tokens (max ${MAX_AGENT_ARG_TOKENS}).`;
  for (const t of tokens) {
    if (typeof t !== 'string' || t.length === 0) return 'Agent-argument tokens must be non-empty strings.';
    if (t.length > MAX_AGENT_ARG_LEN) return `An agent-argument token is too long (max ${MAX_AGENT_ARG_LEN} characters).`;
    if (/[\x00-\x1f\x7f]/.test(t)) return 'Agent-argument tokens must not contain control characters.';
  }
  return null;
}

/**
 * Builds `sbx run --name <name> [-- AGENT_ARGS...]` to re-attach to an
 * existing sandbox. The -- separator is omitted entirely when there are no
 * agent args, matching how a user would type the command by hand.
 */
export function buildRunExistingArgs({ name, agentArgs }) {
  if (!name || !String(name).trim()) throw new Error('A sandbox name is required.');
  const tail = agentArgs || [];
  const invalidReason = validateAgentArgs(tail);
  if (invalidReason) throw new Error(invalidReason);
  const args = ['sbx', 'run', '--name', String(name).trim()];
  if (tail.length > 0) args.push('--', ...tail);
  return args;
}

/** Builds `sbx stop <name>`. */
export function buildStopArgs(name) {
  if (!name || !String(name).trim()) throw new Error('A sandbox name is required.');
  return ['sbx', 'stop', String(name).trim()];
}

/** Builds `sbx rm --force <name>`. --force skips the CLI's interactive confirmation. */
export function buildRemoveArgs(name) {
  if (!name || !String(name).trim()) throw new Error('A sandbox name is required.');
  return ['sbx', 'rm', '--force', String(name).trim()];
}

/**
 * Builds `sbx policy allow|deny network --sandbox <name> <resources>`.
 * Resources are joined into a single comma-separated argv token, as the CLI
 * expects (RESOURCES is one comma-separated list, not repeated flags).
 */
export function buildPolicyAddArgs({ name, decision, resources }) {
  if (!name || !String(name).trim()) throw new Error('A sandbox name is required.');
  if (decision !== 'allow' && decision !== 'deny') throw new Error('decision must be "allow" or "deny".');
  if (!resources || resources.length === 0) throw new Error('At least one resource is required.');
  return ['sbx', 'policy', decision, 'network', '--sandbox', String(name).trim(), resources.join(',')];
}

/**
 * Builds `sbx policy rm network --sandbox <name> --id <ruleId>` or
 * `--resource <resource>`. Exactly one of ruleId/resource must be given.
 */
export function buildPolicyRemoveArgs({ name, ruleId, resource }) {
  if (!name || !String(name).trim()) throw new Error('A sandbox name is required.');
  if (!ruleId && !resource) throw new Error('Either ruleId or resource is required.');
  const args = ['sbx', 'policy', 'rm', 'network', '--sandbox', String(name).trim()];
  if (ruleId) args.push('--id', String(ruleId));
  else args.push('--resource', String(resource));
  return args;
}

// hostname / *.host / **.host / ** / optional :port. Each dot-separated label
// is letters, digits, '-', or '*' in any position — real sbx policy data
// includes mid-label wildcards like "crl*.digicert.com", not just a
// wildcard-only leading label. Port digits are their own capture group so
// isValidNetworkResource can additionally range-check them (0-99999 matches
// the regex, but only 1-65535 is a real TCP port).
const RESOURCE_RE = /^[A-Za-z0-9*-]+(?:\.[A-Za-z0-9*-]+)*(?::([0-9]{1,5}))?$/;

/** Is `s` a valid `sbx policy allow|deny network` resource entry? */
export function isValidNetworkResource(s) {
  if (typeof s !== 'string') return false;
  const trimmed = s.trim();
  if (!trimmed || trimmed !== s) return false;
  if (/\s/.test(trimmed)) return false;
  if (trimmed.startsWith('-')) return false; // never let a resource look like a CLI flag
  const match = RESOURCE_RE.exec(trimmed);
  if (!match) return false;
  if (match[1] !== undefined) {
    const port = Number(match[1]);
    if (port < 1 || port > 65535) return false;
  }
  return true;
}

/** Splits free-text resource input on commas and/or whitespace, trimming and dropping empties. */
export function parseResourceList(text) {
  if (!text) return [];
  return text
    .split(/[\s,]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

/** Upper bound on resources per policy add request — server and client share it. */
export const MAX_RESOURCES_PER_REQUEST = 64;

/** Formats one `sbx ls --json` published-port entry the way its PORTS column reads. */
export function formatPort(port) {
  const arrow = `${port.host_port}->${port.sandbox_port}/${port.protocol}`;
  return port.host_ip ? `${port.host_ip}:${arrow}` : arrow;
}
