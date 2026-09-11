import SbxKit

/// An `actor`, not `Task.detached` — PLAN.md's Phase 3 design. Serialization
/// is the point: two rapid root changes must not interleave, and because
/// `DirectoryScanner.scanTree` runs synchronously inside the caller's own
/// `Task`, cancelling that task's cooperative cancellation flag propagates
/// into the scan for free (it already checks `Task.isCancelled` at every
/// directory boundary).
public actor ScanService: TreeScanning {
    public init() {}

    public func scan(root: String, maxDepth: Int, ignoreFolders: Set<String>) async -> ScannedTree {
        let scanner = DirectoryScanner(maxDepth: maxDepth, ignoreFolders: ignoreFolders)
        let nodes = scanner.scanTree(root: root)
        return ScannedTree(nodes: nodes)
    }
}
