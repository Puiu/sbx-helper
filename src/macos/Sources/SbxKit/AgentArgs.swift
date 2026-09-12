// Ports src/electron/public/shared/sandbox-commands.mjs — AGENT_DEFAULT_ARGS,
// defaultAgentArgs, tokenizeArgs, validateAgentArgs, and the two size limits.

/// Per-agent default trailing args for "Run" on an existing sandbox.
let agentDefaultArgs: [String: [String]] = ["claude": ["--model", "opusplan"]]

/// Every built-in agent `sbx run` accepts (from `sbx run --help`'s
/// "Available agents" line). Order is the CLI's own order.
public let supportedAgents: [String] = [
    "claude", "codex", "copilot", "cursor", "devin", "docker-agent",
    "droid", "gemini", "kiro", "opencode", "shell",
]

/// Infers the agent from a template name via case-insensitive substring
/// match, or nil when no agent name appears (caller keeps the current
/// selection). Earliest occurrence in the template wins on multiple
/// matches; ties fall back to `supportedAgents` order.
public func inferAgent(fromTemplate template: String) -> String? {
    guard !template.isEmpty else { return nil }
    let lowered = template.lowercased()
    var best: (offset: Int, order: Int, agent: String)?
    for (order, agent) in supportedAgents.enumerated() {
        guard let range = lowered.range(of: agent.lowercased()) else { continue }
        let offset = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
        if let current = best {
            if offset < current.offset || (offset == current.offset && order < current.order) {
                best = (offset, order, agent)
            }
        } else {
            best = (offset, order, agent)
        }
    }
    return best?.agent
}

/// Default agent-args tail for `agent`, or [] if it has none.
public func defaultAgentArgs(_ agent: String) -> [String] {
    agentDefaultArgs[agent] ?? []
}

public let maxAgentArgTokens = 32
public let maxAgentArgLen = 256

/// Splits free-text agent args into argv tokens. A real (if minimal) POSIX
/// word-splitter, not just "whole-token '...'/\"...\" quoting" — it has to
/// be, to round-trip with quotePosix(), which escapes an embedded single
/// quote as the `'\''` idiom: close the quote, emit a backslash-escaped
/// literal quote outside of any quoting, reopen the quote. Adjacent quoted
/// and unquoted runs with no separating whitespace concatenate into one
/// token, exactly as a POSIX shell would join them — that's what makes the
/// live preview truthful to what will actually run. Never throws, even on
/// an unterminated quote (the rest of the string is just consumed as a
/// literal token) — this is a best-effort tokenizer for a live preview, not
/// a strict parser.
///
/// Iterates unicodeScalars, not Character: a `'` followed by a combining
/// mark is one Character that `== "'"` is false for, which would make the
/// tokenizer miss a quote JS's UTF-16-indexed loop sees. All delimiters
/// here are ASCII, so scalar iteration matches JS everywhere reachable.
public func tokenizeArgs(_ text: String) -> [String] {
    var tokens: [String] = []
    guard !text.isEmpty else { return tokens }

    let scalars = Array(text.unicodeScalars)
    let n = scalars.count
    var i = 0
    var current = String.UnicodeScalarView()
    var inToken = false

    func pushCurrent() {
        if inToken { tokens.append(String(current)) }
        current = String.UnicodeScalarView()
        inToken = false
    }

    while i < n {
        let ch = scalars[i]

        if isJSWhitespace(ch) {
            pushCurrent()
            i += 1
            continue
        }

        if ch == "'" {
            inToken = true
            i += 1
            while i < n, scalars[i] != "'" {
                current.append(scalars[i])
                i += 1
            }
            i += 1 // skip the closing quote (or run past the end, for an unterminated one)
            continue
        }

        if ch == "\"" {
            inToken = true
            i += 1
            while i < n, scalars[i] != "\"" {
                if scalars[i] == "\\", i + 1 < n, scalars[i + 1] == "\"" || scalars[i + 1] == "\\" {
                    current.append(scalars[i + 1])
                    i += 2
                } else {
                    current.append(scalars[i])
                    i += 1
                }
            }
            i += 1
            continue
        }

        if ch == "\\" {
            inToken = true
            i += 1
            if i < n {
                current.append(scalars[i])
                i += 1
            }
            continue
        }

        inToken = true
        current.append(ch)
        i += 1
    }
    pushCurrent()
    return tokens
}

/// Structural validation only — an arbitrary agent flag is the feature, not
/// something to allowlist by content. Bounds size and rules out control
/// characters (a newline inside a token would make the preview lie about
/// what runs). Returns nil when acceptable, else the reason.
public func validateAgentArgs(_ tokens: [String]) -> SbxKitError? {
    if tokens.count > maxAgentArgTokens { return .tooManyAgentArgTokens(max: maxAgentArgTokens) }
    for t in tokens {
        if t.isEmpty { return .emptyAgentArgToken }
        if t.utf16.count > maxAgentArgLen { return .agentArgTokenTooLong(max: maxAgentArgLen) }
        if t.unicodeScalars.contains(where: { ($0.value <= 0x1f) || $0.value == 0x7f }) {
            return .agentArgControlCharacter
        }
    }
    return nil
}
