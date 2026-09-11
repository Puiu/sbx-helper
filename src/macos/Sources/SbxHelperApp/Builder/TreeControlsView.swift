import SwiftUI
import SbxAppCore

/// The filter field + git-only toggle bar above the tree — `app.js`'s
/// `.tree-controls`. `filterText`/`gitOnly` are session-only, never written
/// to config, matching Electron (`app.js:1309-1321`).
struct TreeControlsView: View {
    @Environment(BuilderModel.self) private var environmentBuilder
    var filterFocused: FocusState<BuilderField?>.Binding

    var body: some View {
        @Bindable var builder = environmentBuilder

        HStack(spacing: 14) {
            TextField("Filter folders…  (press /)", text: $builder.filterText)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.paper)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .stroke(Theme.hairlineStrong, lineWidth: 1)
                )
                .focused(filterFocused, equals: .filter)

            Toggle("git repos only", isOn: $builder.gitOnly)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}
