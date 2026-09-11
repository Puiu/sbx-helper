import SwiftUI
import SbxAppCore

/// Ports app.js's command block + actions (index.html:70-79,
/// refreshCommand 360-392, doCopy 465-483, doRun 485-515). `.ready` renders
/// the monospaced command; `.unavailable` blanks the block entirely and
/// shows only the error hint — the JS never puts placeholder text in the
/// `<pre>`.
struct CommandPreviewView: View {
    @Environment(BuilderModel.self) private var builder
    @State private var showingSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            commandBlock

            if case .unavailable(let message) = builder.commandPreview {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger)
            }

            HStack(spacing: 8) {
                Button("Copy") { builder.copyCommand() }
                    .disabled(!builder.canCopy)

                Button(builder.isLaunching ? "Launching…" : "Run in iTerm") {
                    Task { await builder.run() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!builder.canRun)

                // index.html's `#saveBtn` — enabled exactly when the command
                // builds (app.js's refreshCommand), independent of launch
                // state. Owns its sheet locally, like the toolbar's sheets.
                Button("Save preset") { showingSave = true }
                    .disabled(!builder.canSavePreset)
            }
        }
        .sheet(isPresented: $showingSave) { SavePresetSheet() }
    }

    private var commandBlock: some View {
        let display: String = {
            if case .ready(let display) = builder.commandPreview { return display }
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
