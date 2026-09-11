// Tests the internal parity primitives in Sources/SbxKit/Support.swift —
// the string-comparison helpers everything else relies on to match JS.
import Testing
@testable import SbxKit

@Suite("JSOrder")
struct JSOrderTests {
    // JS compares UTF-16 code units ordinally; Swift's `<` normalizes for
    // canonical equivalence. "Å" (U+00C5) vs "A" + combining ring (U+0041
    // U+030A) are canonically equivalent but must NOT compare equal here —
    // JS sees 0x41 < 0xC5, so the NFD form sorts first.
    @Test("NFD form sorts before NFC form, matching JS UTF-16 ordinal compare")
    func nfdVsNfcOrdinalCompare() {
        let nfd = "A\u{030A}"
        let nfc = "Å"
        #expect(JSOrder.precedes(nfd, nfc))
        #expect(!JSOrder.precedes(nfc, nfd))
    }

    @Test("plain ASCII compares as expected")
    func asciiOrdering() {
        #expect(JSOrder.precedes("A", "B"))
        #expect(!JSOrder.precedes("B", "A"))
        #expect(!JSOrder.precedes("A", "A"))
    }
}

@Suite("FinderOrder")
struct FinderOrderTests {
    @Test("repo2 sorts before repo10 (numeric-aware, diverges from JS localeCompare)")
    func numericAwareOrdering() {
        #expect(FinderOrder.precedes("repo2", "repo10"))
        #expect(!FinderOrder.precedes("repo10", "repo2"))
    }

    @Test("a case-only difference resolves to a deterministic strict order")
    func caseOnlyTieBreak() {
        let a = "readme"
        let b = "README"
        let ab = FinderOrder.precedes(a, b)
        let ba = FinderOrder.precedes(b, a)
        #expect(ab != ba)
    }
}

@Suite("isJSWhitespace")
struct IsJSWhitespaceTests {
    @Test(
        "classifies characters the way JS's \\s does",
        arguments: [
            (" " as Unicode.Scalar, true),
            ("\t" as Unicode.Scalar, true),
            ("\n" as Unicode.Scalar, true),
            ("\u{FEFF}" as Unicode.Scalar, true), // BOM — in JS \s, NOT in Swift's isWhitespace
            ("a" as Unicode.Scalar, false),
        ]
    )
    func classifiesWhitespace(scalar: Unicode.Scalar, expected: Bool) {
        #expect(isJSWhitespace(scalar) == expected)
    }
}
