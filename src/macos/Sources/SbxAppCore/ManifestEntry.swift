import SbxKit

/// Ports src/electron/public/app.js's renderManifest (340-356) and
/// manifestRow (302-338) — pure derivation from the current selection into
/// what the manifest pane lists, so it's testable without SwiftUI.
public struct ManifestEntry: Sendable, Equatable, Identifiable {
    public let path: String
    public let kind: SelectionKind
    public let isPrimary: Bool

    public var id: String { path }

    /// The path plus a display-only ":ro" suffix for read-only rows — the
    /// suffix never appears in `path` itself, only here.
    public var displayPath: String {
        kind == .readOnly ? path + ":ro" : path
    }

    public var note: String {
        if isPrimary { return "primary" }
        if kind == .readOnly { return "read-only" }
        return ""
    }

    /// "★" for the primary, "☆" for a non-primary editable row, "" for a
    /// read-only row (app.js renders that case `visibility: hidden` rather
    /// than removing the element, so it still occupies layout width — the
    /// view must reserve that width, not drop the element).
    public var star: String {
        if isPrimary { return "★" }
        if kind == .editable { return "☆" }
        return ""
    }

    public var canBePrimary: Bool { kind == .editable }
}

/// Order: all editable paths sorted, then all read-only paths sorted. The
/// primary is NOT hoisted to the top here, unlike `orderedWorkspaces` for
/// the command — app.js's renderManifest sorts each bucket independently
/// and never special-cases the primary's position.
public func manifestEntries(editable: [String], readOnly: [String], primary: String?) -> [ManifestEntry] {
    let resolved = resolvePrimary(editable, explicit: primary)
    let editableEntries = editable.sorted(by: JSOrder.precedes).map {
        ManifestEntry(path: $0, kind: .editable, isPrimary: $0 == resolved)
    }
    let readOnlyEntries = readOnly.sorted(by: JSOrder.precedes).map {
        ManifestEntry(path: $0, kind: .readOnly, isPrimary: false)
    }
    return editableEntries + readOnlyEntries
}
