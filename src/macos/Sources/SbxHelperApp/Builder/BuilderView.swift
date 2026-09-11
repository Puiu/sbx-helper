import SwiftUI
import SbxAppCore

/// One case per text-entry site in the Builder tab (PLAN.md's state model)
/// — lets the tree's key handlers ask "is any field focused?" the way
/// app.js's `typing` guard (`activeElement.tagName`) does, without each
/// view owning an opaque `Bool`.
enum BuilderField: Hashable {
    case filter
    case customTemplate
    case sandboxName
    // No .rootField/.presetName: the Phase 5 sheets own their focus with
    // local @FocusState, and a sheet is a separate presentation — its keys
    // never bubble into FolderTreeView's `.onKeyPress` handlers, so the
    // shared typing guard needs no new cases.
}

/// `HSplitView`, not `NavigationSplitView` — the tree and manifest panes are
/// peers, not sidebar/detail (PLAN.md). The Electron grid is
/// `minmax(0, 1fr) 340px`; `HSplitView` is draggable, so the manifest pane
/// takes an ideal/min width instead of a hard constraint.
struct BuilderView: View {
    @Environment(BuilderModel.self) private var builder

    // Owned here, not in TreeControlsView, so `/` can move focus into the
    // filter field from the tree area too — the analogue of app.js's
    // `typing` guard (onBuilderKeydown, app.js:1243), which focuses the
    // filter unless a text field already has it.
    @FocusState private var focusedField: BuilderField?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TreeControlsView(filterFocused: $focusedField)
                FolderTreeView()
                    .onKeyPress(KeyEquivalent("/")) {
                        guard focusedField == nil else { return .ignored }
                        focusedField = .filter
                        return .handled
                    }
                    .onKeyPress(.leftArrow) { handleLeftArrow() }
                    .onKeyPress(.rightArrow) { handleRightArrow() }
                    .onKeyPress(characters: CharacterSet(charactersIn: "eE")) { _ in
                        handleToggle(.editable)
                    }
                    .onKeyPress(characters: CharacterSet(charactersIn: "rR")) { _ in
                        handleToggle(.readOnly)
                    }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

            ManifestView(focusedField: $focusedField)
                .frame(minWidth: 280, idealWidth: 340, maxHeight: .infinity)
        }
    }

    /// Ports app.js:1258-1261 — expands the cursor's node if it has
    /// children. Deliberately does not move the cursor into the first
    /// child, and does not preventDefault (returns `.ignored` when it
    /// doesn't act, letting the key still reach `List`).
    private func handleRightArrow() -> KeyPress.Result {
        guard focusedField == nil, let cursor = builder.cursor,
              !(builder.tree.index.childrenOf[cursor] ?? []).isEmpty else { return .ignored }
        if !builder.expanded.contains(cursor) {
            builder.toggleExpanded(cursor)
        }
        return .handled
    }

    /// Ports app.js:1262-1265 — collapses the cursor's node if expanded.
    /// Does not jump to the parent when already collapsed.
    private func handleLeftArrow() -> KeyPress.Result {
        guard focusedField == nil, let cursor = builder.cursor,
              builder.expanded.contains(cursor) else { return .ignored }
        builder.toggleExpanded(cursor)
        return .handled
    }

    /// Ports the `e`/`r` toggles (app.js:1270-1283). Guarded on
    /// `focusedField == nil` (SwiftUI's focus system replaces the JS's
    /// `activeElement.tagName` check) and on no modifiers — unlike the JS,
    /// which matches on `e.key` alone and so lets `⌘E` fire too; this is a
    /// deliberate fix, not a port (Decision 2).
    private func handleToggle(_ kind: SelectionKind) -> KeyPress.Result {
        guard focusedField == nil, let cursor = builder.cursor else { return .ignored }
        builder.toggleSelection(cursor, kind)
        return .handled
    }
}
