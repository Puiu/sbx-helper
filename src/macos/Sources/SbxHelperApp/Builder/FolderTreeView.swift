import SwiftUI
import SbxAppCore

/// `List` over the flattened `visibleRows`, `.listStyle(.plain)` —
/// PLAN.md's chosen approach over `OutlineGroup`/`NSTableView`: `List`
/// already flattens filter + gitOnly + expansion into one array, and
/// `List(selection:)` gives free ↑/↓ navigation with scroll-into-view and
/// row recycling with stable identity.
struct FolderTreeView: View {
    @Environment(BuilderModel.self) private var environmentBuilder

    var body: some View {
        @Bindable var builder = environmentBuilder
        let rows = builder.visibleRows

        ZStack {
            if rows.isEmpty, !builder.tree.nodes.isEmpty {
                Text("No folders match.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(rows, selection: $builder.cursor) { node in
                    FolderRowView(
                        node: node,
                        isExpanded: node.depth == 0 || builder.expanded.contains(node.path),
                        hasChildren: !(builder.tree.index.childrenOf[node.path] ?? []).isEmpty,
                        toggleExpanded: { builder.toggleExpanded(node.path) }
                    )
                }
                .listStyle(.plain)
                .accessibilityLabel("Folders")
            }

            if builder.isScanning {
                ProgressView()
            }
        }
    }
}
