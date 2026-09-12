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
    /// Whether the `sbx` binary resolves right now — nil until the first
    /// `checkSbxAvailability()`. Tracked separately from `configBanner`:
    /// a missing binary is an environment problem with a Settings fix, not
    /// a degraded config, and it must surface as its own banner rather than
    /// an empty template list (PLAN.md Phase 8).
    public private(set) var sbxAvailable: Bool?
    private let sbxProbe: @Sendable () async -> Bool

    public init(configStore: ConfigStore, sbxProbe: @escaping @Sendable () async -> Bool = { true }) {
        self.configStore = configStore
        self.config = defaultConfig()
        self.sbxProbe = sbxProbe
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

    /// Re-resolves `sbx` through the injected probe. Called at launch and
    /// after the Settings sheet saves a new `sbxPath`. The production probe
    /// re-resolves fresh each time (see SbxHelperApp), so both installing
    /// AND uninstalling `sbx` mid-session are picked up by the next check.
    public func checkSbxAvailability() async {
        sbxAvailable = await sbxProbe()
    }

    /// The persistent "sbx not found" banner (PLAN.md Phase 8) — nil while
    /// availability is unknown or the binary resolves. Same wording as
    /// `SandboxesModel`'s `.toolNotFound` toast so both surfaces agree.
    public var sbxBanner: String? {
        sbxAvailable == false ? "sbx not found — set its location in Settings." : nil
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
