import Testing
import SbxKit
@testable import SbxAppCore

struct ScanServiceTests {
    @Test
    func scansARealDirectoryAndBuildsAMatchingIndex() async {
        let dir = TempDirectory()
        dir.makeDirectory("child")
        dir.makeDirectory("child/.git") // marks "child" as a git repo

        let service = ScanService()
        let tree = await service.scan(root: dir.path, maxDepth: 3, ignoreFolders: [])

        #expect(tree.nodes.first?.path == dir.path)
        #expect(tree.nodes.first?.depth == 0)
        #expect(tree.nodes.contains { $0.path == dir.joined("child") && $0.isGitRepo })
        #expect(tree.index.byPath[dir.path] != nil)
        #expect(tree.index.childrenOf[dir.path] == [dir.joined("child")])
    }

    @Test
    func respectsIgnoreFolders() async {
        let dir = TempDirectory()
        dir.makeDirectory("node_modules")
        dir.makeDirectory("keepme")

        let service = ScanService()
        let tree = await service.scan(root: dir.path, maxDepth: 3, ignoreFolders: ["node_modules"])

        #expect(!tree.nodes.contains { $0.path == dir.joined("node_modules") })
        #expect(tree.nodes.contains { $0.path == dir.joined("keepme") })
    }
}
