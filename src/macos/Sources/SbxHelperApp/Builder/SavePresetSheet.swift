import SwiftUI
import SbxAppCore

/// Ports src/electron/public/app.js's save dialog (636-676): a name field
/// with autofocus, an inline error (app.js's `saveError` — validation
/// failures never toast), Cancel/Esc and Save/Enter. Dismisses on success;
/// the saved/overwritten toast comes from `BuilderModel.savePreset`.
struct SavePresetSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(BuilderModel.self) private var builder
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save preset")
                .font(.headline)

            TextField("preset name", text: $name)
                .focused($nameFocused)
                .disableAutocorrection(true)
                .onSubmit(save)

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // No `.defaultAction`: Enter already reaches `save()` through
                // `.onSubmit` — a default button would save twice, and the
                // second pass would report "overwritten" for a fresh preset.
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .onAppear { nameFocused = true }
    }

    private func save() {
        Task {
            let message = await builder.savePreset(name: name, existingPresets: app.config.presets)
            if let message {
                error = message
            } else {
                dismiss()
            }
        }
    }
}
