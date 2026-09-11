// Ports src/electron/lib/scan.mjs — scanTree. Measured on a real checkout:
// 316 directories at depth 3 in ~15ms (677 at depth 4 in ~53ms) — cheap
// enough to scan the whole tree eagerly rather than lazily expanding nodes.
import Foundation

public struct DirectoryScanner: Sendable {
    public var maxDepth: Int
    public var ignoreFolders: Set<String>

    public init(maxDepth: Int, ignoreFolders: Set<String>) {
        self.maxDepth = maxDepth
        self.ignoreFolders = ignoreFolders
    }

    /// Returns a flat, depth-first pre-order array of TreeNode. The root
    /// itself is the first element (depth 0) and is always included, even
    /// if unreadable. Checks `Task.isCancelled` at each directory boundary
    /// and returns what it has so far rather than throwing — a caller's
    /// generation counter is expected to discard stale results.
    public func scanTree(root: String) -> [TreeNode] {
        scanTree(root: root, isCancelled: { Task.isCancelled })
    }

    /// Testable seam: real cancellation is a Task-timing race, which makes
    /// it untestable deterministically through the ambient `Task.isCancelled`
    /// alone. `internal`, not `public` — production callers always want the
    /// real ambient check via the overload above.
    func scanTree(root: String, isCancelled: @Sendable () -> Bool) -> [TreeNode] {
        var nodes: [TreeNode] = []
        visit(root, depth: 0, isCancelled: isCancelled, into: &nodes)
        return nodes
    }

    private func visit(_ dirPath: String, depth: Int, isCancelled: @Sendable () -> Bool, into nodes: inout [TreeNode]) {
        var unreadable = false
        var childDirNames: [String] = []

        if let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dirPath, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [] // deliberately not .skipsHiddenFiles — the dot-prefix filter below is manual
        ) {
            for entryURL in entries {
                let name = entryURL.lastPathComponent
                guard !name.hasPrefix("."), !ignoreFolders.contains(name) else { continue }

                let values = try? entryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                // Skip symlinks outright, even to directories — matches
                // Node's Dirent.isDirectory(), which is lstat-based and
                // would exclude a symlink-to-directory too. Checked before
                // .isDirectory because that key resolves the link.
                if values?.isSymbolicLink == true { continue }
                guard values?.isDirectory == true else { continue }

                childDirNames.append(name)
            }
        } else {
            unreadable = true
        }

        // Plain file-exists check, not is-directory — a worktree's or
        // --clone's .git is a *file*, and this must still count as a repo.
        let isGitRepo = FileManager.default.fileExists(atPath: (dirPath as NSString).appendingPathComponent(".git"))

        nodes.append(TreeNode(
            path: dirPath,
            name: depth == 0 ? dirPath : (dirPath as NSString).lastPathComponent,
            depth: depth,
            isGitRepo: isGitRepo,
            unreadable: unreadable
        ))

        // Checked here, after this node is already appended — never before.
        // A cancellation caught before appending would drop whatever node
        // was being visited, which for the very first call is the root
        // itself, violating "root is always the first element" for anyone
        // still holding this (now-stale) result.
        guard !unreadable, !isCancelled(), depth < maxDepth else { return }

        // Finder-style, numeric-aware sort — a deliberate divergence from
        // the JS's plain `.localeCompare` (see PLAN.md): "repo2" sorts
        // before "repo10", matching what the user sees in Finder.
        for name in childDirNames.sorted(by: FinderOrder.precedes) {
            visit((dirPath as NSString).appendingPathComponent(name), depth: depth + 1, isCancelled: isCancelled, into: &nodes)
        }
    }
}
