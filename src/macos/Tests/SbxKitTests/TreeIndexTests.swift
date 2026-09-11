// Net-new tests — this logic is lifted out of untested src/electron/public/app.js
// (indexTree, computeHasGitDescendant, lines 61-97). Written by reading the
// JS directly, since no ported test file exists.
import Testing
@testable import SbxKit

/// root
///   A
///     A1
///   B
///     B1  (isGitRepo: true)
private func makeFixtureNodes() -> [TreeNode] {
    [
        TreeNode(path: "/root", name: "/root", depth: 0, isGitRepo: false, unreadable: false),
        TreeNode(path: "/root/A", name: "A", depth: 1, isGitRepo: false, unreadable: false),
        TreeNode(path: "/root/A/A1", name: "A1", depth: 2, isGitRepo: false, unreadable: false),
        TreeNode(path: "/root/B", name: "B", depth: 1, isGitRepo: false, unreadable: false),
        TreeNode(path: "/root/B/B1", name: "B1", depth: 2, isGitRepo: true, unreadable: false),
    ]
}

@Suite("TreeIndex")
struct TreeIndexTests {
    @Test("wires parent/child relationships from a flat pre-order array")
    func wiresParentChild() {
        let index = TreeIndex(makeFixtureNodes())
        #expect(index.childrenOf["/root"] == ["/root/A", "/root/B"])
        #expect(index.childrenOf["/root/A"] == ["/root/A/A1"])
        #expect(index.childrenOf["/root/A/A1"] == nil)
        #expect(index.parentOf["/root/A/A1"] == "/root/A")
        #expect(index.parentOf["/root/B"] == "/root")
        #expect(index.parentOf["/root"] == nil) // root has no parent
    }

    @Test("indexes every node by path")
    func indexesByPath() {
        let index = TreeIndex(makeFixtureNodes())
        #expect(index.byPath["/root/B/B1"]?.isGitRepo == true)
    }

    @Test("hasGitDescendant propagates up from a deep child")
    func hasGitDescendantPropagatesUp() {
        let index = TreeIndex(makeFixtureNodes())
        #expect(index.hasGitDescendant["/root/B/B1"] == true) // itself
        #expect(index.hasGitDescendant["/root/B"] == true) // child has it
        #expect(index.hasGitDescendant["/root"] == true) // propagates to the top
        #expect(index.hasGitDescendant["/root/A"] == false) // no git anywhere in this branch
        #expect(index.hasGitDescendant["/root/A/A1"] == false)
    }

    @Test("ancestors(of:) returns nearest-first, root last")
    func ancestorsNearestFirst() {
        let index = TreeIndex(makeFixtureNodes())
        #expect(index.ancestors(of: "/root/A/A1") == ["/root/A", "/root"])
        #expect(index.ancestors(of: "/root") == [])
    }
}
