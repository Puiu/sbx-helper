import Testing
import SbxKit
@testable import SbxAppCore

struct ScannedTreeTests {
    @Test
    func emptyHasNoNodesAndAnEmptyIndex() {
        let empty = ScannedTree.empty
        #expect(empty.nodes.isEmpty)
        #expect(empty.index.byPath.isEmpty)
    }

    @Test
    func initBuildsAMatchingIndexFromNodes() {
        let root = TreeNode(path: "/root", name: "/root", depth: 0, isGitRepo: false, unreadable: false)
        let child = TreeNode(path: "/root/child", name: "child", depth: 1, isGitRepo: true, unreadable: false)
        let tree = ScannedTree(nodes: [root, child])

        #expect(tree.nodes == [root, child])
        #expect(tree.index.byPath["/root/child"] == child)
        #expect(tree.index.childrenOf["/root"] == ["/root/child"])
        #expect(tree.index.hasGitDescendant["/root"] == true)
    }
}
