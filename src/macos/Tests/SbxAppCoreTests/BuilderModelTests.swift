import Testing
import SbxKit
@testable import SbxAppCore

@MainActor
struct BuilderModelTests {
    private static let root = TreeNode(path: "/root", name: "/root", depth: 0, isGitRepo: false, unreadable: false)
    private static let repoChild = TreeNode(path: "/root/repo", name: "repo", depth: 1, isGitRepo: true, unreadable: false)
    private static let plainChild = TreeNode(path: "/root/plain", name: "plain", depth: 1, isGitRepo: false, unreadable: false)
    private static let grandchild = TreeNode(path: "/root/repo/deep", name: "deep", depth: 2, isGitRepo: false, unreadable: false)

    private func scannedModel() async -> BuilderModel {
        let scanner = StubScanner()
        // Pre-order: a node's children must immediately follow it, before
        // any siblings — TreeIndex's stack-based parent detection assumes
        // this (matching the real DirectoryScanner's traversal order).
        let tree = ScannedTree(nodes: [Self.root, Self.repoChild, Self.grandchild, Self.plainChild])
        scanner.setResult(tree, for: "/root")
        scanner.release("/root")

        let model = BuilderModel(scanner: scanner, toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in })
        model.scan(root: "/root", maxDepth: 3, ignoreFolders: [])
        await model.quiesce()
        return model
    }

    @Test
    func rootIsAlwaysVisibleAndItsChildrenAreShownByDefault() async {
        let model = await scannedModel()
        // Root (depth 0) is always treated as expanded — app.js:171.
        #expect(model.visibleRows.map(\.path) == ["/root", "/root/repo", "/root/plain"])
    }

    @Test
    func grandchildIsHiddenUntilItsParentIsExpanded() async {
        let model = await scannedModel()
        #expect(!model.visibleRows.contains { $0.path == "/root/repo/deep" })

        model.toggleExpanded("/root/repo")

        #expect(model.visibleRows.map(\.path) == ["/root", "/root/repo", "/root/repo/deep", "/root/plain"])
    }

    @Test
    func toggleExpandedIsIdempotentlyReversible() async {
        let model = await scannedModel()
        model.toggleExpanded("/root/repo")
        #expect(model.visibleRows.contains { $0.path == "/root/repo/deep" })

        model.toggleExpanded("/root/repo")
        #expect(!model.visibleRows.contains { $0.path == "/root/repo/deep" })
    }

    @Test
    func gitOnlyPrunesBranchesWithNoGitDescendant() async {
        let model = await scannedModel()
        model.gitOnly = true
        #expect(model.visibleRows.map(\.path) == ["/root", "/root/repo"])
    }

    @Test
    func filterTextForceExpandsAndKeepsMatchingAncestors() async {
        let model = await scannedModel()
        model.filterText = "deep"
        // "deep" only matches the grandchild — its ancestors must still show
        // (app.js's matchesSubtree), and its parent auto-expands even though
        // it's not in the `expanded` set.
        #expect(model.visibleRows.map(\.path) == ["/root", "/root/repo", "/root/repo/deep"])
    }

    @Test
    func emptyTreeHasNoVisibleRows() {
        let model = BuilderModel(scanner: StubScanner(), toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in })
        #expect(model.visibleRows.isEmpty)
    }
}
