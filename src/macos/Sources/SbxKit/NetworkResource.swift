// Ports src/electron/public/shared/sandbox-commands.mjs — RESOURCE_RE,
// isValidNetworkResource, parseResourceList, MAX_RESOURCES_PER_REQUEST.

// hostname / *.host / **.host / ** / optional :port. Each dot-separated
// label is letters, digits, '-', or '*' in any position — real sbx policy
// data includes mid-label wildcards like "crl*.digicert.com", not just a
// wildcard-only leading label. Hand-rolled rather than Regex: Regex's
// default grapheme-cluster matching semantics diverge from JS's per-code-
// unit regex for any non-ASCII input; this is a pure-ASCII character-class
// test over the whole string, which is more faithful and just as short.
private func matchesResourcePattern(_ s: String) -> Bool {
    let labels = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let host = labels[0]
    guard !host.isEmpty else { return false }

    func isLabelScalar(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "A"..."Z", "a"..."z", "0"..."9", "*", "-":
            return true
        default:
            return false
        }
    }

    let dotSeparated = host.split(separator: ".", omittingEmptySubsequences: false)
    for label in dotSeparated {
        guard !label.isEmpty, label.unicodeScalars.allSatisfy(isLabelScalar) else { return false }
    }

    if labels.count == 2 {
        let portDigits = labels[1]
        guard !portDigits.isEmpty, portDigits.count <= 5,
            portDigits.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 })
        else { return false }
    }
    return true
}

private func portCapture(_ s: String) -> Int? {
    guard let colonIndex = s.lastIndex(of: ":") else { return nil }
    let after = s[s.index(after: colonIndex)...]
    return Int(after)
}

/// Is `s` a valid `sbx policy allow|deny network` resource entry?
public func isValidNetworkResource(_ s: String) -> Bool {
    let trimmed = jsTrim(s)
    guard !trimmed.isEmpty, trimmed == s else { return false }
    guard !s.unicodeScalars.contains(where: isJSWhitespace) else { return false }
    guard !trimmed.hasPrefix("-") else { return false } // never let a resource look like a CLI flag
    guard matchesResourcePattern(trimmed) else { return false }
    if let port = portCapture(trimmed) {
        guard port >= 1, port <= 65535 else { return false }
    }
    return true
}

/// Splits free-text resource input on commas and/or whitespace, trimming and dropping empties.
public func parseResourceList(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    return text.unicodeScalars
        .split(whereSeparator: { $0 == "," || isJSWhitespace($0) })
        .map { jsTrim(String(String.UnicodeScalarView($0))) }
        .filter { !$0.isEmpty }
}

/// Upper bound on resources per policy add request.
public let maxResourcesPerRequest = 64
