import SwiftUI
import SbxAppCore

/// The Builder tab's toolbar slot — `index.html`'s `#builderTopbarControls`:
/// `root <path> [change] [presets]`. Each button owns its sheet locally;
/// sheets are separate presentations, so their keys never reach the tree's
/// `.onKeyPress` handlers the way a shared focus scope would need guarding.
struct BuilderToolbarSlotView: View {
    @Environment(AppModel.self) private var app
    @State private var showingRootPicker = false
    @State private var showingPresets = false

    var body: some View {
        HStack(spacing: 6) {
            Text("root")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            Text(app.config.rootPath)
                .font(Theme.mono(11))
                .lineLimit(1)
                .truncationMode(.middle)
            Button("change") { showingRootPicker = true }
            Button("presets") { showingPresets = true }
        }
        .sheet(isPresented: $showingRootPicker) { RootPickerSheet() }
        .sheet(isPresented: $showingPresets) { PresetsSheet() }
    }
}
