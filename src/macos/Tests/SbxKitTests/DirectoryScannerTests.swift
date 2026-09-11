// Ports src/electron/test/scan.test.mjs (scanTree describe block), plus the
// six directory-scanning parity traps from PLAN.md as separately-named
// tests — a failure must say which trap broke, and each needs its own
// fixture.
import Foundation
import Testing
@testable import SbxKit

private func makeFixture() -> TempDirectory {
    let dir = TempDirectory()
    dir.makeDirectory("A/A1")
    dir.makeDirectory("A/.git") // stand-in repo marker
    dir.makeDirectory("B")
    dir.makeDirectory("B/node_modules/x")
    dir.makeDirectory(".hidden")
    return dir
}

@Suite("scanTree")
struct DirectoryScannerTests {
    @Test("respects maxDepth")
    func respectsMaxDepth() {
        let dir = makeFixture()
        let scanner = DirectoryScanner(maxDepth: 1, ignoreFolders: [])
        let nodes = scanner.scanTree(root: dir.path)
        #expect(nodes.contains { $0.path == dir.joined("A") })
        #expect(!nodes.contains { $0.path == dir.joined("A/A1") })
    }

    @Test("skips ignoreFolders and dot-folders")
    func skipsIgnoreFoldersAndDotFolders() {
        let dir = makeFixture()
        let scanner = DirectoryScanner(maxDepth: 3, ignoreFolders: ["node_modules"])
        let nodes = scanner.scanTree(root: dir.path)
        #expect(!nodes.contains { $0.name == "node_modules" })
        #expect(!nodes.contains { $0.name == ".hidden" })
    }

    @Test("marks isGitRepo from a .git entry")
    func marksIsGitRepo() {
        let dir = makeFixture()
        let scanner = DirectoryScanner(maxDepth: 2, ignoreFolders: [])
        let nodes = scanner.scanTree(root: dir.path)
        #expect(nodes.first { $0.path == dir.joined("A") }?.isGitRepo == true)
        #expect(nodes.first { $0.path == dir.joined("B") }?.isGitRepo == false)
    }

    @Test("marks an unreadable directory rather than throwing")
    func marksUnreadableDirectory() {
        let dir = makeFixture()
        let locked = dir.makeDirectory("locked")
        try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

        let scanner = DirectoryScanner(maxDepth: 2, ignoreFolders: [])
        let nodes = scanner.scanTree(root: dir.path)
        let node = nodes.first { $0.path == locked }
        #expect(node != nil, "the unreadable directory itself should still be listed")
        #expect(node?.unreadable == true)
    }

    // --- Parity traps from PLAN.md, each its own fixture and its own test ---

    @Test("trap 1: pre-order, root at index 0 with depth 0 and name == full path")
    func trap1RootIsFirstWithFullPathName() {
        let dir = makeFixture()
        let scanner = DirectoryScanner(maxDepth: 2, ignoreFolders: [])
        let nodes = scanner.scanTree(root: dir.path)
        #expect(nodes.first?.path == dir.path)
        #expect(nodes.first?.depth == 0)
        #expect(nodes.first?.name == dir.path)
    }

    @Test("trap 2: root is always emitted, even when unreadable")
    func trap2RootEmittedEvenWhenUnreadable() {
        let dir = TempDirectory()
        try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        let scanner = DirectoryScanner(maxDepth: 2, ignoreFolders: [])
        let nodes = scanner.scanTree(root: dir.path)
        #expect(nodes.count == 1)
        #expect(nodes[0].path == dir.path)
        #expect(nodes[0].unreadable == true)
    }

    @Test("trap 3: isGitRepo is a plain file-exists check, not is-directory — matches a worktree's .git file")
    func trap3GitFileNotDirectory() {
        let dir = TempDirectory()
        dir.makeDirectory("worktree")
        dir.makeFile("worktree/.git", contents: "gitdir: /elsewhere/.git/worktrees/w\n")

        let scanner = DirectoryScanner(maxDepth: 1, ignoreFolders: [])
        let nodes = scanner.scanTree(root: dir.path)
        #expect(nodes.first { $0.path == dir.joined("worktree") }?.isGitRepo == true)
    }

    @Test("trap 4: a symlinked directory is skipped, not followed")
    func trap4SkipsSymlinkedDirectory() {
        let dir = TempDirectory()
        dir.makeDirectory("real")
        dir.makeSymlink("link-to-real", to: dir.joined("real"))

        let scanner = DirectoryScanner(maxDepth: 1, ignoreFolders: [])
        let nodes = scanner.scanTree(root: dir.path)
        #expect(nodes.contains { $0.path == dir.joined("real") })
        #expect(!nodes.contains { $0.path == dir.joined("link-to-real") })
    }

    @Test("trap 5: the dot-prefix filter is manual, not FileManager's hidden-flag option")
    func trap5ManualDotPrefixFilter() {
        // A file with the macOS "hidden" flag set, but whose name does NOT
        // start with a dot, must still be scanned — `.skipsHiddenFiles`
        // would also honor that flag; `name.startsWith('.')` (JS) does not.
        let dir = TempDirectory()
        let visiblyNamed = dir.makeDirectory("not-dot-prefixed")
        try! (URL(fileURLWithPath: visiblyNamed) as NSURL).setResourceValue(true, forKey: .isHiddenKey)

        let scanner = DirectoryScanner(maxDepth: 1, ignoreFolders: [])
        let nodes = scanner.scanTree(root: dir.path)
        #expect(nodes.contains { $0.path == visiblyNamed })
    }

    // A cancelled scan is a real concurrency race against the ambient
    // Task.isCancelled state — this drives the cancellation check through
    // an injectable seam instead, so the test is deterministic rather than
    // timing-dependent.
    @Test("a cancelled scan still returns the root node, never an empty array")
    func cancelledScanStillReturnsRoot() {
        let dir = makeFixture()
        let scanner = DirectoryScanner(maxDepth: 2, ignoreFolders: [])
        let nodes = scanner.scanTree(root: dir.path, isCancelled: { true })
        #expect(nodes.count == 1)
        #expect(nodes[0].path == dir.path)
        #expect(nodes[0].depth == 0)
    }

    @Test("cancellation checked mid-scan still keeps every node visited before it")
    func cancellationMidScanKeepsAlreadyVisitedNodes() {
        let dir = makeFixture()
        let scanner = DirectoryScanner(maxDepth: 2, ignoreFolders: [])
        // Not actually concurrent — scanTree is synchronous — so a plain
        // mutable counter is safe despite the @Sendable closure type.
        nonisolated(unsafe) var callCount = 0
        // Root's own check passes (false); every check from then on is
        // cancelled — root and its two depth-1 children (A, B, in Finder
        // order) still get appended before their own cancellation check
        // stops further recursion into A1 / node_modules.
        let nodes = scanner.scanTree(root: dir.path, isCancelled: {
            callCount += 1
            return callCount > 1
        })
        #expect(nodes.map(\.path) == [dir.path, dir.joined("A"), dir.joined("B")])
    }

    @Test("trap 6: siblings sort Finder-style (repo2 before repo10)")
    func trap6FinderStyleSort() {
        let dir = TempDirectory()
        dir.makeDirectory("repo10")
        dir.makeDirectory("repo2")

        let scanner = DirectoryScanner(maxDepth: 1, ignoreFolders: [])
        let nodes = scanner.scanTree(root: dir.path)
        let names = nodes.dropFirst().map(\.name)
        #expect(names == ["repo2", "repo10"])
    }
}
