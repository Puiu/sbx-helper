// Ports src/electron/public/shared/command.mjs — quotePosix, formatCommand.
//
// The output lands in a real `#!/bin/sh` script the user's shell executes —
// a quoting bug here is live shell injection into their own terminal. Keep
// this byte-for-byte with the JS.

// SAFE_UNQUOTED = /^[A-Za-z0-9._/:-]+$/ — a pure-ASCII character-class test
// over the whole string. Hand-rolled rather than Regex: Regex's default
// grapheme-cluster matching semantics diverge from JS's per-code-unit regex
// for any non-ASCII input, and this is simpler than working around that.
// The `+` means an empty string is NOT safe (quotes to `''`), matching the
// JS regex exactly.
private func isSafeUnquoted(_ arg: String) -> Bool {
    guard !arg.isEmpty else { return false }
    for scalar in arg.unicodeScalars {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "/", ":", "-":
            continue
        default:
            return false
        }
    }
    return true
}

/// Quotes a single shell argument for POSIX (macOS/Linux) shells.
public func quotePosix(_ arg: String) -> String {
    if isSafeUnquoted(arg) { return arg }
    return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Joins already-ordered argv into a single display/paste-able command string.
public func formatCommand(_ args: [String]) -> String {
    args.map(quotePosix).joined(separator: " ")
}
