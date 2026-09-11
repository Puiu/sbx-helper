import SbxKit

/// Bundles a scan's flat node list with the `TreeIndex` built from it, so a
/// view or model can never hold an index that's stale relative to its nodes.
public struct ScannedTree: Sendable {
    public let nodes: [TreeNode]
    public let index: TreeIndex

    public init(nodes: [TreeNode]) {
        self.nodes = nodes
        self.index = TreeIndex(nodes)
    }

    public static let empty = ScannedTree(nodes: [])
}
