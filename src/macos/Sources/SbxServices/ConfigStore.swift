// Wraps SbxKit's already-ported loadConfig/saveConfig with an in-memory
// copy plus debounced disk writes, so a rapid sequence of UI-driven edits
// (e.g. retyping an agent-args tail) doesn't hit disk on every keystroke.
import Foundation
import SbxKit

public actor ConfigStore {
    private let path: String
    private var config: AppConfig
    public let loadError: String?
    public let droppedPresets: Int
    public let hadUnrecoverableFieldShape: Bool
    private let debounceInterval: Duration
    private var pendingSaveTask: Task<Void, Never>?

    public init(path: String, debounceInterval: Duration = .milliseconds(300)) {
        self.path = path
        self.debounceInterval = debounceInterval
        let loaded = loadConfig(path)
        self.config = loaded.config
        self.loadError = loaded.error
        self.droppedPresets = loaded.droppedPresets
        self.hadUnrecoverableFieldShape = loaded.hadUnrecoverableFieldShape
    }

    /// Mirrors `LoadedConfig.isDegraded` — a UI built on `ConfigStore` alone
    /// (which only kept the individual fields) couldn't otherwise reconstruct
    /// this without re-deriving the same formula itself.
    public var isDegraded: Bool { loadError != nil || droppedPresets > 0 || hadUnrecoverableFieldShape }

    public func current() -> AppConfig { config }

    /// Applies `transform` to the in-memory config immediately (visible to
    /// the very next `current()` call) and schedules a debounced disk write.
    public func update(_ transform: (inout AppConfig) -> Void) {
        transform(&config)
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        let path = self.path
        let snapshot = config
        let interval = debounceInterval
        pendingSaveTask = Task {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            saveConfig(path, snapshot)
        }
    }

    /// Forces an immediate write of whatever is currently in memory,
    /// bypassing the debounce — for AppDelegate's terminate-time flush.
    public func flush() async {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        saveConfig(path, config)
    }
}
