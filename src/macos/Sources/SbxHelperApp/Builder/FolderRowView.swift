import SwiftUI
import SbxKit
import SbxAppCore

/// One row in the folder tree — `app.js`'s `renderTree()`: indent,
/// disclosure, name, git/unreadable badges, the covered-by reason, and the
/// tri-state selection control. A selected row gets the app's permission
/// tint (Theme.swift's design thesis: deep amber = writable, steel blue =
/// read-only); a covered row's name greys out.
struct FolderRowView: View {
    @Environment(BuilderModel.self) private var builder

    let node: TreeNode
    let isExpanded: Bool
    let hasChildren: Bool
    let toggleExpanded: () -> Void

    private var selection: SelectionKind? { builder.selection[node.path] }

    var body: some View {
        // Computed once per body evaluation rather than as a computed
        // property re-evaluated at each of its three use sites below —
        // `coveredByLabel(for:)` does real work (a covering-path lookup).
        let coveredByLabel = builder.coveredByLabel(for: node.path)

        HStack(spacing: 6) {
            disclosureButton
            Text(node.name)
                .font(Theme.mono(12))
                .foregroundStyle(coveredByLabel != nil ? Theme.muted : Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if node.isGitRepo {
                TreeBadgeView("git")
            }
            if node.unreadable {
                TreeBadgeView("unreadable", tint: Theme.danger)
            }
            if let coveredByLabel {
                Text(coveredByLabel)
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            SegmentedTriStateView(
                selection: selection,
                isLocked: coveredByLabel != nil,
                onChange: { builder.setSelection(node.path, $0) }
            )
            // app.js's per-row `finder` button — opens the folder as its
            // own Finder window. Silent on success; `BuilderModel.reveal`
            // toasts every failure.
            Button("finder") { builder.reveal(node.path) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .help("Open in Finder")
        }
        .padding(.leading, Theme.indentBase + CGFloat(node.depth) * Theme.indentPerLevel)
        .padding(.trailing, 12)
        .padding(.vertical, Theme.rowVerticalPadding)
        .background(rowTint)
        .overlay(alignment: .leading) {
            stripeColor.frame(width: 3)
        }
    }

    @ViewBuilder
    private var rowTint: some View {
        switch selection {
        case .editable: Theme.writeBg
        case .readOnly: Theme.readBg
        case nil: Color.clear
        }
    }

    private var stripeColor: Color {
        switch selection {
        case .editable: Theme.write
        case .readOnly: Theme.read
        case nil: .clear
        }
    }

    private var disclosureButton: some View {
        Button(action: toggleExpanded) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
        }
        .buttonStyle(.plain)
        .frame(width: Theme.disclosureWidth, height: 18)
        // Leaves keep the chevron's indent slot but hide the glyph itself —
        // styles.css:302's `:disabled { visibility: hidden }`, not removal.
        .opacity(hasChildren ? 1 : 0)
        .disabled(!hasChildren)
    }
}
