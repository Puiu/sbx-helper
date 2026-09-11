// New — Swift has no path.relative()/path.resolve(). Purely lexical (no
// symlink resolution, no filesystem access): do NOT use
// NSString.standardizingPath, which resolves symlinks and rewrites
// /private/tmp -> /tmp for absolute paths — that would make a temp-dir-based
// test fail mysteriously. Ports the relativizePreset/absolutizePreset half
// of src/electron/lib/config.mjs.

private func pathSegments(_ path: String) -> [Substring] {
    path.split(separator: "/", omittingEmptySubsequences: true)
}

/// Mirrors Node's `path.relative(from, to)` for two absolute paths, purely
/// lexically. Returns `""` for equal paths — `app.js`'s `joinPath` special-
/// cases `""` (and `"."`) back to root, so this must round-trip through
/// `resolvePath`.
public func relativePath(from base: String, to target: String) -> String {
    let baseSegs = pathSegments(base)
    let targetSegs = pathSegments(target)

    var common = 0
    while common < baseSegs.count, common < targetSegs.count, baseSegs[common] == targetSegs[common] {
        common += 1
    }

    let upCount = baseSegs.count - common
    var parts = Array(repeating: "..", count: upCount)
    parts.append(contentsOf: targetSegs[common...].map(String.init))
    return parts.joined(separator: "/")
}

private func normalizeAbsolute(_ path: String) -> String {
    var stack: [Substring] = []
    for seg in pathSegments(path) {
        switch seg {
        case ".":
            continue
        case "..":
            if !stack.isEmpty { stack.removeLast() }
        default:
            stack.append(seg)
        }
    }
    return "/" + stack.joined(separator: "/")
}

/// Mirrors Node's `path.resolve(base, relative)`: an **absolute** `relative`
/// argument wins and discards `base` entirely. This is a deliberate parity
/// fix — `app.js`'s hand-rolled `joinPath("/root", "/abs")` yields
/// `/root//abs`, while the Electron server's own `absolutizePreset` (built
/// on Node's real `path.resolve`) yields `/abs`; the two were already
/// inconsistent with each other. `resolvePath(base, "")` and
/// `resolvePath(base, ".")` both return `base` unchanged.
public func resolvePath(_ base: String, _ relative: String) -> String {
    if relative.hasPrefix("/") {
        return normalizeAbsolute(relative)
    }
    let combined = base.hasSuffix("/") ? base + relative : base + "/" + relative
    return normalizeAbsolute(combined)
}

/// Absolute editable/readOnly paths -> stored relative to the preset's own rootPath.
public func relativizePreset(rootPath: String, _ preset: Preset) -> Preset {
    var result = preset
    result.editable = preset.editable.map { relativePath(from: rootPath, to: $0) }
    result.readOnly = preset.readOnly.map { relativePath(from: rootPath, to: $0) }
    return result
}

/// Stored relative paths -> absolute paths under the preset's rootPath.
public func absolutizePreset(_ preset: Preset) -> (editable: [String], readOnly: [String]) {
    (
        editable: preset.editable.map { resolvePath(preset.rootPath, $0) },
        readOnly: preset.readOnly.map { resolvePath(preset.rootPath, $0) }
    )
}
