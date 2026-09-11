// Ports src/electron/server.mjs's apiPresets (192-229) and the apiScan root
// handling (155-175). The Node server validated preset fields and resolved
// the new root before persisting; that server layer doesn't exist in the
// native app, so the same rules move here as pure functions. BuilderModel
// calls them and persists the result through AppModel.update.
import Foundation

/// Ports apiPresets' save branch: trims the name, requires at least one
/// editable path, trims the template with fallback to `defaultTemplate`,
/// normalizes a blank `sandboxName` to nil, and stores paths relative to
/// `rootPath` (via relativizePreset — the on-disk schema keeps relative
/// paths, exactly as the JS's relativizePreset produces).
public func buildPreset(
    name: String,
    rootPath: String,
    template: String,
    defaultTemplate: String,
    sandboxName: String?,
    clone: Bool,
    editable: [String],
    readOnly: [String]
) throws(SbxKitError) -> Preset {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { throw .presetNameRequired }
    guard !editable.isEmpty else { throw .presetRequiresEditable }
    let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTemplate = trimmedTemplate.isEmpty ? defaultTemplate : trimmedTemplate
    let trimmedSandboxName = (sandboxName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let preset = Preset(
        name: trimmedName,
        rootPath: rootPath,
        template: resolvedTemplate,
        sandboxName: trimmedSandboxName.isEmpty ? nil : trimmedSandboxName,
        clone: clone,
        editable: editable,
        readOnly: readOnly
    )
    return relativizePreset(rootPath: rootPath, preset)
}

/// Ports the JS's findIndex/upsert: replaces the same-named preset in place,
/// appends otherwise. Returns whether an existing preset was overwritten —
/// the JS reports that so the toast can say "overwritten" vs "saved".
public func upsertPreset(_ preset: Preset, into presets: [Preset]) -> (presets: [Preset], overwritten: Bool) {
    if let idx = presets.firstIndex(where: { $0.name == preset.name }) {
        var result = presets
        result[idx] = preset
        return (result, true)
    }
    return (presets + [preset], false)
}

/// Ports apiPresets' delete branch — drops every preset with `name`.
public func deletePreset(named name: String, from presets: [Preset]) -> [Preset] {
    presets.filter { $0.name != name }
}

/// Ports apiScan's root validation (server.mjs:155-167): trims, requires
/// non-empty, then existence and directory-ness. `path.resolve` has no
/// observable effect on an already-absolute Cocoa path beyond normalization,
/// so the resolved value here is the trimmed input — callers pass absolute
/// paths and the checks below enforce it the same way the JS's statSync did
/// (a relative path simply fails `exists`).
public func resolveRoot(
    _ raw: String,
    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    isDirectory: (String) -> Bool = { var isDir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
) throws(SbxKitError) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw .rootPathRequired }
    // Node's `path.resolve` (which apiScan applies before validating) strips
    // trailing slashes, so "/repos/" and "/repos" are the same root there —
    // normalize here too, before the checks, so the returned root and any
    // error message match what the JS reported.
    var normalized = trimmed
    while normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
    guard exists(normalized) else { throw .pathNotFound(path: normalized) }
    guard isDirectory(normalized) else { throw .notADirectory(path: normalized) }
    return normalized
}

/// Ports apiScan's recent-roots bookkeeping (server.mjs:170): prepends the
/// resolved root, dedupes, and caps at 8.
public func recordRecentRoot(_ resolved: String, in recent: [String], cap: Int = 8) -> [String] {
    Array(([resolved] + recent.filter { $0 != resolved }).prefix(cap))
}
