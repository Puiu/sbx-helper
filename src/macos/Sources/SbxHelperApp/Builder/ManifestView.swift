import SwiftUI
import SbxAppCore

/// Replaces `ManifestPlaceholderView` — Workspaces/Settings/Command,
/// keeping the placeholder's shell (ScrollView, padding, hairline rule) so
/// the pane's geometry doesn't shift between Phase 3 and Phase 4.
struct ManifestView: View {
    @Environment(BuilderModel.self) private var builder
    var focusedField: FocusState<BuilderField?>.Binding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                workspacesSection
                section("Settings") { BuilderSettingsView(focusedField: focusedField) }
                section("Command") { CommandPreviewView() }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.hairline).frame(width: 1)
        }
    }

    private var workspacesSection: some View {
        section("Workspaces") {
            if builder.manifest.isEmpty {
                // Verbatim from index.html's #manifestEmpty hint, with "e"
                // and "r" styled as key caps.
                (
                    Text("Nothing selected. Click a folder, or press ")
                        + Text("e").font(Theme.mono(11)).foregroundStyle(Theme.ink)
                        + Text(" (editable) / ")
                        + Text("r").font(Theme.mono(11)).foregroundStyle(Theme.ink)
                        + Text(" (read-only) on the highlighted row.")
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(builder.manifest) { entry in
                        ManifestRowView(
                            entry: entry,
                            onSetPrimary: { builder.setPrimary(entry.path) },
                            onRemove: { builder.setSelection(entry.path, nil) }
                        )
                    }
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(Theme.muted)
            content()
        }
    }
}
