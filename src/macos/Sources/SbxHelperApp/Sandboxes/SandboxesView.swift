import SwiftUI
import SbxAppCore

/// The Sandboxes tab — ports index.html:83-112's `#sandboxesPanel` (minus
/// the policy section, which stays Phase 7's) and app.js:815-849's
/// fetch/select wiring. `HSplitView`, like the Builder tab: the list and
/// the detail are peers, not sidebar/detail.
struct SandboxesView: View {
    @Environment(SandboxesModel.self) private var environmentSandboxes

    var body: some View {
        @Bindable var sandboxes = environmentSandboxes

        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                if let error = sandboxes.sandboxesError {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.danger)
                        .padding(8)
                }

                // The list and the debug log are vertical peers in a
                // draggable splitter, so the log's height is
                // user-adjustable per session and its overflow scrolls
                // inside its allocation instead of squeezing the list.
                VSplitView {
                    Group {
                        if sandboxes.sandboxesLoaded, sandboxes.sandboxesError == nil, sandboxes.sandboxes.isEmpty {
                            Text("No sandboxes found.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .padding(12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            // `List(selection:)` gives ↑/↓ navigation with
                            // scroll-into-view plus row recycling for free — the
                            // native analogue of app.js:1298-1304's
                            // `onSandboxesKeydown` arrow handling, which therefore
                            // needs no `.onKeyPress` port.
                            List(
                                sandboxes.sandboxes,
                                selection: Binding(
                                    get: { sandboxes.selectedName },
                                    set: { if let name = $0 { sandboxes.select(name) } }
                                )
                            ) { sandbox in
                                SandboxRowView(sandbox: sandbox)
                                    .tag(sandbox.name)
                            }
                            .listStyle(.plain)
                        }
                    }
                    .frame(minHeight: 80, maxHeight: .infinity)

                    // Live sbx command/response log — collapsed by default.
                    // Lives in the list pane (not the detail pane) so it stays
                    // visible when the list itself fails to load, which is
                    // exactly when its contents matter most.
                    SandboxDebugLogView()
                        .padding(8)
                        .frame(minHeight: 28, idealHeight: 120, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

            Group {
                if let selected = sandboxes.selectedSandbox {
                    SandboxDetailView(sandbox: selected)
                } else {
                    Text("Select a sandbox to see details and actions.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.paper)
                }
            }
            .frame(minWidth: 280, idealWidth: 340, maxHeight: .infinity)
        }
        // Lazy first load — ports app.js:1196's `if (!onBuilder &&
        // !state.sandboxesLoaded) fetchSandboxes()`: the tab fetches on
        // first appearance, and the `sandboxesLoaded` guard inside the
        // model is not needed because this `.task` only runs while the tab
        // is visible while `sandboxesLoaded` is still false.
        .task {
            if !sandboxes.sandboxesLoaded {
                await sandboxes.fetch()
            }
        }
    }
}
