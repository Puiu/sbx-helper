// Ports src/electron/test/selection.test.mjs.
import Testing
@testable import SbxKit

@Suite("isAncestor")
struct IsAncestorTests {
    @Test("true for a direct parent/child pair")
    func trueForDirectParentChild() {
        #expect(isAncestor("/root/A", of: "/root/A/B"))
    }

    @Test("false for a same-prefix sibling")
    func falseForSamePrefixSibling() {
        #expect(!isAncestor("/root/A", of: "/root/AB"))
    }

    @Test("false for a path compared to itself")
    func falseForSelfComparison() {
        #expect(!isAncestor("/root/A", of: "/root/A"))
    }
}

@Suite("findCoveringPath")
struct FindCoveringPathTests {
    @Test("flags a descendant of an already-selected folder")
    func flagsDescendant() {
        #expect(findCoveringPath("/root/A/B", in: ["/root/A"]) == "/root/A")
    }

    @Test("flags an ancestor of an already-selected folder")
    func flagsAncestor() {
        #expect(findCoveringPath("/root/A", in: ["/root/A/B"]) == "/root/A/B")
    }

    @Test("returns nil when there is no overlap")
    func noOverlap() {
        #expect(findCoveringPath("/root/C", in: ["/root/A", "/root/B"]) == nil)
    }
}

@Suite("findAnyConflict")
struct FindAnyConflictTests {
    @Test("catches a nested pair anywhere in the list")
    func catchesNestedPair() {
        #expect(findAnyConflict(["/root/A", "/root/C", "/root/A/B"]) != nil)
    }

    @Test("returns nil for a fully disjoint list")
    func disjointList() {
        #expect(findAnyConflict(["/root/A", "/root/B", "/root/C"]) == nil)
    }
}

@Suite("resolvePrimary")
struct ResolvePrimaryTests {
    @Test("defaults to the ordinal-first editable path")
    func defaultsToOrdinalFirst() {
        #expect(resolvePrimary(["/root/B", "/root/A"], explicit: nil) == "/root/A")
    }

    @Test("honors an explicit override that is still editable")
    func honorsStillEditableOverride() {
        #expect(resolvePrimary(["/root/B", "/root/A"], explicit: "/root/B") == "/root/B")
    }

    @Test("ignores an override no longer in the editable set")
    func ignoresStaleOverride() {
        #expect(resolvePrimary(["/root/B", "/root/A"], explicit: "/root/Z") == "/root/A")
    }

    @Test("returns nil when nothing is editable")
    func nilWhenNothingEditable() {
        #expect(resolvePrimary([], explicit: "/root/A") == nil)
    }
}
