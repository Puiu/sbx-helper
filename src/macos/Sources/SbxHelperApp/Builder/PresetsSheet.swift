import SwiftUI
import SbxAppCore

/// Ports src/electron/public/app.js's presets dialog (678-783): one row per
/// preset with the `template · N editable, M read-only · rootPath` meta
/// line, Load and Delete actions, and the "No saved presets yet." empty
/// state. Load dismisses (app.js closes the dialog after applying);
/// Delete stays open and the list re-renders from `app.config` (app.js's
/// `renderPresetsDialog` after delete).
struct PresetsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(BuilderModel.self) private var builder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Presets")
                .font(.headline)

            if app.config.presets.isEmpty {
                Text("No saved presets yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            } else {
                List {
                    ForEach(app.config.presets) { preset in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.system(size: 13, weight: .semibold))
                                Text("\(preset.template) · \(preset.editable.count) editable, \(preset.readOnly.count) read-only · \(preset.rootPath)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Button("Load") {
                                Task {
                                    // Stays open on a missing-root failure
                                    // (loadPreset toasts it), like the JS.
                                    if await builder.loadPreset(
                                        preset,
                                        maxDepth: app.config.maxDepth,
                                        ignoreFolders: Set(app.config.ignoreFolders)
                                    ) {
                                        dismiss()
                                    }
                                }
                            }
                            Button("Delete") {
                                Task { await builder.deletePreset(name: preset.name) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 160, maxHeight: 320)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520)
    }
}
