// The two top-level views, replacing src/electron/public/index.html's
// role="tablist" tab bar with a native segmented Picker + View menu (⌘1/⌘2).
public enum AppTab: String, Sendable, CaseIterable, Identifiable {
    case builder
    case sandboxes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .builder: "Builder"
        case .sandboxes: "Sandboxes"
        }
    }
}
