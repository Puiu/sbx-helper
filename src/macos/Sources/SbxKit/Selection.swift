// Ports src/electron/public/shared/selection.mjs — pure path-prefix logic
// for the "no nested mounts" rule, and for picking the primary workspace.

private func normalize(_ p: String) -> String {
    if p.hasSuffix("/") && p.count > 1 {
        return String(p.dropLast())
    }
    return p
}

/// Is `ancestor` a strict ancestor directory of `of`?
public func isAncestor(_ ancestor: String, of path: String) -> Bool {
    let a = normalize(ancestor)
    let b = normalize(path)
    return a != b && b.hasPrefix(a + "/")
}

/// Returns the selected path that makes `candidate` invalid to also select
/// (because one would be nested inside the other), or nil if `candidate` is
/// free to select. `selectedPaths` should not include `candidate` itself.
public func findCoveringPath(_ candidate: String, in selectedPaths: some Sequence<String>) -> String? {
    for s in selectedPaths {
        if s == candidate { continue }
        if isAncestor(s, of: candidate) || isAncestor(candidate, of: s) { return s }
    }
    return nil
}

/// First conflicting pair found in an arbitrary path list, or nil. Used as a
/// backstop in case a caller ever assembles a bad selection.
public func findAnyConflict(_ paths: [String]) -> String? {
    for i in 0..<paths.count {
        for j in (i + 1)..<paths.count {
            if isAncestor(paths[i], of: paths[j]) { return "\(paths[j]) is inside \(paths[i])" }
            if isAncestor(paths[j], of: paths[i]) { return "\(paths[i]) is inside \(paths[j])" }
        }
    }
    return nil
}

/// The primary workspace: an explicit override if it's still editable, else
/// the ordinal-first editable path (a stable, order-independent default).
public func resolvePrimary(_ editablePaths: [String], explicit explicitPrimary: String?) -> String? {
    guard !editablePaths.isEmpty else { return nil }
    if let explicitPrimary, editablePaths.contains(explicitPrimary) {
        return explicitPrimary
    }
    return editablePaths.sorted(by: JSOrder.precedes).first
}
