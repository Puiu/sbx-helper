import SwiftUI
import SbxKit
import SbxAppCore

/// The selected sandbox's detail + run section — ports app.js:904-975's
/// `renderSandboxDetail`/`refreshSandboxCommand` and index.html:91-112's
/// `#sandboxDetailEmpty`/`#sandboxDetailSection`/`#sandboxRunSection`,
/// plus the policy section (index.html:114-126, `PolicyListView`).
struct SandboxDetailView: View {
    @Environment(SandboxesModel.self) private var environmentSandboxes
    let sandbox: Sandbox

    var body: some View {
        @Bindable var sandboxes = environmentSandboxes

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Selected sandbox")
                    .font(.system(size: 13, weight: .semibold))

                summaryGrid

                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent args")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                    // A get/set Binding over the model's drafts — the field
                    // edits session state, never the stored config, until
                    // Run persists the normalized form (server.mjs:407-410).
                    TextField(
                        "e.g. --model opusplan",
                        text: Binding(
                            get: { sandboxes.draftText(for: sandbox) },
                            set: { sandboxes.setDraft($0, for: sandbox.name) }
                        )
                    )
                    .font(Theme.mono(12))
                    .textFieldStyle(.roundedBorder)
                }

                commandBlock(sandboxes: sandboxes)

                if case .unavailable(let message) = sandboxes.commandPreview {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.danger)
                }

                HStack(spacing: 8) {
                    Button("Run") { Task { await sandboxes.run() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!sandboxes.canRun)

                    Button("Stop") { Task { await sandboxes.stop() } }
                        .disabled(!sandboxes.canStop)

                    Button("Delete") { sandboxes.requestDelete() }
                        .disabled(!sandboxes.canDelete)
                }

                PolicyListView()
            }
            .padding(12)
        }
        // The model owns `showsDeleteConfirm` so a failed removal leaves
        // the alert open — the analogue of the JS dialog's inline
        // `deleteSandboxError`, which likewise only closes on success.
        .alert("Delete sandbox", isPresented: $sandboxes.showsDeleteConfirm) {
            Button("Cancel", role: .cancel) { sandboxes.cancelDelete() }
            Button("Delete", role: .destructive) { Task { await sandboxes.confirmRemove() } }
        } message: {
            Text(deleteMessage)
        }
    }

    /// Ports app.js:925-939's summary rows (`name/agent/status/ports/
    /// workspace`), with the same `—` fallback for empty ports/workspaces.
    private var summaryGrid: some View {
        Grid(alignment: .leading, verticalSpacing: 2) {
            ForEach(summaryRows, id: \.0) { key, value in
                GridRow {
                    Text(key)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                    Text(value)
                        .font(Theme.mono(12))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var summaryRows: [(String, String)] {
        [
            ("name", sandbox.name),
            ("agent", sandbox.agent),
            ("status", sandbox.status),
            ("ports", sandbox.ports.map(\.formatted).joined(separator: ", ").nilIfEmpty ?? "—"),
            ("workspace", sandbox.workspaces.joined(separator: ", ").nilIfEmpty ?? "—"),
        ]
    }

    /// Ports app.js:1088-1095's `openDeleteSandboxDialog` message plus the
    /// dialog's own warning paragraph (index.html:165-169).
    private var deleteMessage: String {
        let workspaces = sandbox.workspaces.joined(separator: ", ").nilIfEmpty ?? "—"
        return """
        Delete "\(sandbox.name)"? Workspaces: \(workspaces)

        This stops the sandbox, removes its container, cleans up any git \
        worktrees, and deletes its state — including a sandbox that's \
        currently in use (e.g. an open SSH connection). This cannot be undone.
        """
    }

    /// Ports the `#sandboxCommandDisplay` block — blank when the preview
    /// doesn't build (the JS clears the `<pre>` and shows only the error).
    private func commandBlock(sandboxes: SandboxesModel) -> some View {
        let display: String = {
            if case .ready(let display) = sandboxes.commandPreview { return display }
            return ""
        }()

        return Text(display)
            .font(Theme.mono(12))
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            .padding(10)
            .background(Theme.paper)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
            .textSelection(.enabled)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
