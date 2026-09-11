import SwiftUI
import SbxAppCore

/// The Sandboxes tab's toolbar slot — `index.html`'s
/// `#sandboxesTopbarControls`: the sandbox count plus a manual refresh.
struct SandboxesToolbarSlotView: View {
    @Environment(SandboxesModel.self) private var sandboxes

    var body: some View {
        HStack(spacing: 6) {
            Text(sandboxes.sandboxCountLabel)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            Button("Refresh") { Task { await sandboxes.fetch() } }
        }
    }
}
