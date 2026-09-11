// Ports src/electron/lib/scan.mjs — the node shape scanTree emits.

public struct TreeNode: Sendable, Equatable, Identifiable, Hashable {
    public let path: String
    public let name: String
    public let depth: Int
    public let isGitRepo: Bool
    public let unreadable: Bool

    public var id: String { path }

    public init(path: String, name: String, depth: Int, isGitRepo: Bool, unreadable: Bool) {
        self.path = path
        self.name = name
        self.depth = depth
        self.isGitRepo = isGitRepo
        self.unreadable = unreadable
    }
}
