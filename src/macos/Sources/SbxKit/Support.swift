// Internal string-comparison primitives that keep the rest of SbxKit in
// parity with JS's string semantics — Swift's `String` `<`/`==` normalize
// for canonical equivalence, and `sorted(by:)` is not stable, both of which
// diverge from what the ported JS relies on. See PLAN.md's "Support" design
// note for the full rationale.
import Foundation

/// Mirrors `Array.prototype.sort()`'s default comparator: ordinal comparison
/// of UTF-16 code units. Swift's `String` `<` normalizes for canonical
/// equivalence (an NFD sequence can compare equal to its NFC form), which JS
/// never does — use this wherever byte-for-byte parity with a JS `.sort()`
/// or `!==` comparison matters.
enum JSOrder {
    static func precedes(_ a: String, _ b: String) -> Bool {
        a.utf16.lexicographicallyPrecedes(b.utf16)
    }
}

/// Finder-style ordering: `localizedStandardCompare` (numeric-aware — sorts
/// "repo2" before "repo10", unlike JS's `localeCompare`) with an ordinal
/// tie-break. The tie-break exists because `localizedStandardCompare` can
/// return `.orderedSame` for genuinely distinct strings (e.g. a case-only
/// difference), and Swift's `sorted(by:)` is not a stable sort — without a
/// strict total order, sibling rows would shuffle nondeterministically
/// between scans.
enum FinderOrder {
    static func precedes(_ a: String, _ b: String) -> Bool {
        switch a.localizedStandardCompare(b) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return a.utf8.lexicographicallyPrecedes(b.utf8)
        }
    }
}

/// JS's `\s` matches Unicode `White_Space` plus U+FEFF (BOM); Swift's
/// `Character.isWhitespace` / `CharacterSet.whitespacesAndNewlines` /
/// `Unicode.Scalar.Properties.isWhitespace` all exclude U+FEFF. Used by
/// `tokenizeArgs`'s delimiter test.
func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isWhitespace || scalar == "\u{FEFF}"
}

/// Mirrors JS's `String.prototype.trim()`, which strips `isJSWhitespace`
/// from both ends — not Foundation's `.whitespacesAndNewlines`, which
/// excludes U+FEFF.
func jsTrim(_ s: String) -> String {
    var scalars = Substring(s).unicodeScalars
    while let first = scalars.first, isJSWhitespace(first) { scalars.removeFirst() }
    while let last = scalars.last, isJSWhitespace(last) { scalars.removeLast() }
    return String(scalars)
}
