import SwiftUI
import SbxKit
import SbxServices
import SbxAppCore

/// The Settings pane (⌘,) — Phase 8. Today it owns exactly one field: the
/// `sbx` binary location (`AppConfig.sbxPath`), the second tier of
/// `ToolLocator`'s resolution order. An empty field clears the override and
/// falls back to auto-detection. A non-empty field must pass
/// `validateSbxPath` (absolute + exists) before anything persists — the
/// inline `saveError` is the analogue of `RootPickerSheet`'s `rootError`.
///
/// Saving pushes the new value into `ToolLocator` via
/// `updateConfiguredPath` and re-runs the availability check, so the
/// "sbx not found" banner clears (or appears) without a restart.
struct SettingsView: View {
    @Environment(AppModel.self) private var environmentApp
    let locator: ToolLocator

    @State private var sbxPathText = ""
    @State private var saveError: String?
    // Guards the async save below: without it a double-clicked Save (or
    // Submit + click) launches two interleaved update → locator → check
    // sequences and the banner can end up reflecting the older write.
    @State private var isSaving = false

    var body: some View {
        @Bindable var app = environmentApp

        Form {
            Section("sbx location") {
                TextField(
                    "Auto-detect (recommended when empty)",
                    text: $sbxPathText
                )
                .font(Theme.mono(12))
                .onSubmit { save(app) }

                Text("Absolute path to the sbx binary. Leave empty to auto-detect via well-known locations and your login shell.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)

                if let saveError {
                    Text(saveError)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.danger)
                }

                HStack {
                    Spacer()
                    Button("Save") { save(app) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving)
                }
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear { sbxPathText = app.config.sbxPath ?? "" }
    }

    private func save(_ app: AppModel) {
        guard !isSaving else { return }
        let trimmed = sbxPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            do {
                try validateSbxPath(trimmed)
            } catch {
                saveError = error.errorDescription ?? ""
                return
            }
        }
        saveError = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            await app.update { $0.sbxPath = trimmed.isEmpty ? nil : trimmed }
            await locator.updateConfiguredPath(app.config.sbxPath)
            await app.checkSbxAvailability()
        }
    }
}
