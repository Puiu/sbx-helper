// Ports src/electron/lib/templates.mjs — parseTemplateLs (the pure-parsing
// half; the `sbx template ls` invocation itself is Phase 2's SbxServices).

private func isRepositoryHeader(_ line: String) -> Bool {
    let upper = line.uppercased()
    guard upper.hasPrefix("REPOSITORY") else { return false }
    let afterPrefix = upper.index(upper.startIndex, offsetBy: "REPOSITORY".count)
    guard afterPrefix != upper.endIndex else { return true }
    let next = upper[afterPrefix]
    return !(next.isLetter || next.isNumber || next == "_")
}

/// Splits on runs of two or more JS-whitespace characters — mirrors JS's
/// `line.split(/\s{2,}/)`. A single space stays part of the token (table
/// columns are padded with 2+ spaces; a value itself may contain one).
private func splitOnRunsOfTwoOrMoreWhitespace(_ s: String) -> [String] {
    let scalars = Array(s.unicodeScalars)
    var result: [String] = []
    var current = String.UnicodeScalarView()
    var i = 0
    while i < scalars.count {
        if isJSWhitespace(scalars[i]) {
            var j = i
            while j < scalars.count, isJSWhitespace(scalars[j]) { j += 1 }
            if j - i >= 2 {
                if !current.isEmpty {
                    result.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalars[i])
            }
            i = j
        } else {
            current.append(scalars[i])
            i += 1
        }
    }
    if !current.isEmpty { result.append(String(current)) }
    return result
}

/// Splits on the LF scalar alone, matching JS's `.split('\n')`. Not
/// `stdout.split(separator: "\n")` on the Character view: Swift merges
/// "\r\n" into a single extended grapheme cluster, which never equals the
/// Character "\n" — so a CRLF-terminated table would never split at all. JS
/// strings have no grapheme clustering, so `'\n'` there always means the
/// single UTF-16 code unit; any leftover "\r" is stripped by the `jsTrim`
/// below, same as JS's `.trim()` does.
private func splitOnLineFeed(_ s: String) -> [String] {
    var lines: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        if scalar == "\n" {
            lines.append(String(current))
            current = String.UnicodeScalarView()
        } else {
            current.append(scalar)
        }
    }
    lines.append(String(current))
    return lines
}

/// Parses `sbx template ls` table output into "repo:tag" strings, skipping
/// the header row and de-duplicating while preserving first-seen order (JS's
/// `[...new Set(x)]` is insertion-ordered; Swift's `Set` is not).
public func parseTemplateLs(_ stdout: String) -> [String] {
    let lines = splitOnLineFeed(stdout)
        .map { jsTrim($0) }
        .filter { !$0.isEmpty }

    var result: [String] = []
    for line in lines {
        if isRepositoryHeader(line) { continue }
        let cols = splitOnRunsOfTwoOrMoreWhitespace(line)
        if cols.count >= 2, !cols[0].isEmpty, !cols[1].isEmpty {
            result.append("\(cols[0]):\(cols[1])")
        }
    }

    var seen = Set<String>()
    return result.filter { seen.insert($0).inserted }
}
