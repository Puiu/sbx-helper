import SwiftUI
import SbxAppCore

struct RootView: View {
    @Environment(AppModel.self) private var environmentApp

    var body: some View {
        @Bindable var app = environmentApp

        VStack(spacing: 0) {
            if let banner = app.configBanner {
                ErrorBanner(message: banner)
            }
            if let sbxBanner = app.sbxBanner {
                ErrorBanner(message: sbxBanner)
            }

            switch app.activeTab {
            case .builder:
                BuilderView()
            case .sandboxes:
                SandboxesView()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .overlay {
            ToastOverlay()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $app.activeTab) {
                    ForEach(AppTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            ToolbarItemGroup(placement: .primaryAction) {
                switch app.activeTab {
                case .builder:
                    BuilderToolbarSlotView()
                case .sandboxes:
                    SandboxesToolbarSlotView()
                }
            }
        }
    }
}
