// Ports src/electron/public/app.js:61-97 — indexTree, computeHasGitDescendant.
// Folded into one init (rather than a separate reindex() step) to remove the
// "did you remember to call reindex()?" bug class app.js has.

public struct TreeIndex: Sendable {
    public let byPath: [String: TreeNode]
    public let childrenOf: [String: [String]]
    /// Present only for non-root nodes — a missing entry means "no parent",
    /// same falsy semantics as the JS `Map<path, path|null>`.
    public let parentOf: [String: String]
    public let hasGitDescendant: [String: Bool]

    public init(_ nodes: [TreeNode]) {
        var byPath: [String: TreeNode] = [:]
        var childrenOf: [String: [String]] = [:]
        var parentOf: [String: String] = [:]
        var stack: [TreeNode] = []

        for node in nodes {
            byPath[node.path] = node
            while let last = stack.last, last.depth >= node.depth { stack.removeLast() }
            if let parent = stack.last {
                parentOf[node.path] = parent.path
                childrenOf[parent.path, default: []].append(node.path)
            }
            stack.append(node)
        }

        self.byPath = byPath
        self.childrenOf = childrenOf
        self.parentOf = parentOf

        // Descendants appear later than their ancestor in pre-order, so
        // walking backwards guarantees every child of a node is already
        // resolved by the time we reach that node.
        var hasGitDescendant: [String: Bool] = [:]
        for node in nodes.reversed() {
            let kids = childrenOf[node.path] ?? []
            let anyKidHas = kids.contains { hasGitDescendant[$0] == true }
            hasGitDescendant[node.path] = node.isGitRepo || anyKidHas
        }
        self.hasGitDescendant = hasGitDescendant
    }

    /// All ancestor paths of `path`, nearest first, root last.
    public func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = parentOf[path]
        while let p = current {
            result.append(p)
            current = parentOf[p]
        }
        return result
    }
}
