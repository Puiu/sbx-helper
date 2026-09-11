import Observation
import SbxKit
import SbxServices

/// Top-level app state: config, active tab, and the config-health banner.
/// `@Observable`, not `ObservableObject` — per-property invalidation matters
/// (PLAN.md's Phase 3 state model).
@MainActor
@Observable
public final class AppModel {
    public let configStore: ConfigStore
    public private(set) var config: AppConfig
    public var activeTab: AppTab = .builder
    public private(set) var configBanner: String?

    public init(configStore: ConfigStore) {
        self.configStore = configStore
        self.config = defaultConfig()
    }

    public func load() async {
        config = await configStore.current()
        configBanner = await configBannerMessage(
            loadError: configStore.loadError,
            droppedPresets: configStore.droppedPresets,
            hadUnrecoverableFieldShape: configStore.hadUnrecoverableFieldShape
        )
    }

    public func flush() async {
        await configStore.flush()
    }

    /// The only mutation path for `config` — `AppModel` is single-owner of
    /// `AppConfig`, so callers that want to persist a change (Phase 4's
    /// template picker, Phase 5's presets) go through this rather than
    /// touching `configStore` directly, which would let `config` go stale.
    public func update(_ transform: @escaping @Sendable (inout AppConfig) -> Void) async {
        await configStore.update(transform)
        config = await configStore.current()
    }
}
