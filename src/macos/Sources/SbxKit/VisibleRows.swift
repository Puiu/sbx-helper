// Ports src/electron/public/app.js:140-175 — computeVisibleRows. Keeps the
// SwiftUI tree view thin and testable — this filter/expansion logic must not
// live in a View.

public func computeVisibleRows(
    nodes: [TreeNode], index: TreeIndex, filterText: String, gitOnly: Bool, expanded: Set<String>
) -> [TreeNode] {
    let filter = jsTrim(filterText).lowercased()
    let searching = !filter.isEmpty
    var matchCache: [String: Bool] = [:]

    func matchesSubtree(_ node: TreeNode) -> Bool {
        if let cached = matchCache[node.path] { return cached }
        var result = node.name.lowercased().contains(filter)
        if !result {
            let kids = index.childrenOf[node.path] ?? []
            result = kids.contains { kPath in
                guard let child = index.byPath[kPath] else { return false }
                return matchesSubtree(child)
            }
        }
        matchCache[node.path] = result
        return result
    }

    func gitOk(_ node: TreeNode) -> Bool {
        !gitOnly || (index.hasGitDescendant[node.path] ?? false)
    }

    var rows: [TreeNode] = []
    func walk(_ node: TreeNode) {
        guard gitOk(node) else { return }
        if searching, !matchesSubtree(node) { return }
        rows.append(node)
        let isExpanded = searching || node.depth == 0 || expanded.contains(node.path)
        if isExpanded {
            for kPath in index.childrenOf[node.path] ?? [] {
                if let child = index.byPath[kPath] { walk(child) }
            }
        }
    }

    if let root = nodes.first { walk(root) }
    return rows
}
