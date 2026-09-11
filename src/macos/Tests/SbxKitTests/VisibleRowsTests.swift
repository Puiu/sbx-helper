// Net-new tests — this logic is lifted out of untested src/electron/public/app.js
// (computeVisibleRows, lines 140-175). Written by reading the JS directly,
// since no ported test file exists.
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

@Suite("computeVisibleRows")
struct VisibleRowsTests {
    @Test("root is always expanded regardless of the expanded set — its direct children show by default")
    func rootAlwaysExpanded() {
        let nodes = makeFixtureNodes()
        let index = TreeIndex(nodes)
        let rows = computeVisibleRows(nodes: nodes, index: index, filterText: "", gitOnly: false, expanded: [])
        #expect(rows.map(\.path) == ["/root", "/root/A", "/root/B"])
    }

    @Test("a depth-1 node's children are hidden until its path is in the expanded set")
    func expandingRevealsGrandchildren() {
        let nodes = makeFixtureNodes()
        let index = TreeIndex(nodes)
        let rows = computeVisibleRows(
            nodes: nodes, index: index, filterText: "", gitOnly: false, expanded: ["/root/B"]
        )
        #expect(rows.map(\.path) == ["/root", "/root/A", "/root/B", "/root/B/B1"])
    }

    @Test("a filter matching a descendant keeps its ancestors visible, even when collapsed")
    func filterKeepsAncestorsVisible() {
        let nodes = makeFixtureNodes()
        let index = TreeIndex(nodes)
        let rows = computeVisibleRows(
            nodes: nodes, index: index, filterText: "A1", gitOnly: false, expanded: []
        )
        #expect(rows.map(\.path) == ["/root", "/root/A", "/root/A/A1"])
    }

    @Test("a filter with no matches yields an empty result")
    func filterWithNoMatchesYieldsEmpty() {
        let nodes = makeFixtureNodes()
        let index = TreeIndex(nodes)
        let rows = computeVisibleRows(
            nodes: nodes, index: index, filterText: "nonexistent", gitOnly: false, expanded: []
        )
        #expect(rows.isEmpty)
    }

    @Test("gitOnly prunes branches with no git descendant")
    func gitOnlyPrunesBranches() {
        let nodes = makeFixtureNodes()
        let index = TreeIndex(nodes)
        let rows = computeVisibleRows(
            nodes: nodes, index: index, filterText: "", gitOnly: true, expanded: ["/root/A", "/root/B"]
        )
        #expect(rows.map(\.path) == ["/root", "/root/B", "/root/B/B1"])
    }

    @Test("searching force-expands every visited node, not just direct children")
    func searchingForceExpands() {
        let nodes = makeFixtureNodes()
        let index = TreeIndex(nodes)
        // "1" matches both A1 and B1, under two different unexpanded
        // branches — with nothing in the expanded set, both branches must
        // still be traversed and shown, not just the one closest to root.
        let rows = computeVisibleRows(
            nodes: nodes, index: index, filterText: "1", gitOnly: false, expanded: []
        )
        #expect(Set(rows.map(\.path)) == Set(nodes.map(\.path)))
    }
}
