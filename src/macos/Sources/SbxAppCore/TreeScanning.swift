/// A seam over directory scanning so `BuilderModel` can be tested against a
/// stub that controls exactly when a scan completes, without touching the
/// filesystem.
public protocol TreeScanning: Sendable {
    func scan(root: String, maxDepth: Int, ignoreFolders: Set<String>) async -> ScannedTree
}
