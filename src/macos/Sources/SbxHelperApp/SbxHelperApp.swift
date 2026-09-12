import SwiftUI
import SbxKit
import SbxServices
import SbxAppCore

@main
struct SbxHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app: AppModel
    @State private var builder: BuilderModel
    @State private var sandboxes: SandboxesModel
    @State private var toasts: ToastCenter
    private let locator: ToolLocator

    init() {
        let configPath = resolveConfigPath(
            environment: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory()
        )
        // Single synchronous load: `ConfigStore` takes the already-loaded
        // value instead of re-reading the file, and `ToolLocator` takes
        // `config.sbxPath` from that same load.
        let loaded = loadConfig(configPath)
        let configStore = ConfigStore(path: configPath, loaded: loaded)
        let runner = ProcessRunner()
        let locator = ToolLocator(
            commandRunner: runner,
            environment: ProcessInfo.processInfo.environment,
            configuredPath: loaded.config.sbxPath
        )
        self.locator = locator
        let cli = SbxCLI(commandRunner: runner, toolLocator: locator)

        let toasts = ToastCenter()
        // The availability probe closes over `locator` (an actor, so the
        // closure stays `@Sendable`). It invalidates first and re-resolves
        // every time: `resolvedPath` caches successes, and a check that
        // trusted the cache would never notice `sbx` being uninstalled
        // mid-session. Checks only run at launch and after a Settings
        // save, so the occasional shell-probe cost is fine.
        let appModel = AppModel(configStore: configStore, sbxProbe: {
            await locator.invalidateCache()
            return await locator.resolvedPath() != nil
        })
        _toasts = State(initialValue: toasts)
        _app = State(initialValue: appModel)
        let terminalLauncher = TerminalLauncher(commandRunner: runner)
        _sandboxes = State(initialValue: SandboxesModel(
            lister: cli,
            controller: cli,
            policies: cli,
            launcher: terminalLauncher,
            toasts: toasts,
            mutateConfig: { [appModel] transform in
                await appModel.update(transform)
            }
        ))
        // `persistTemplate`/`mutateConfig` close over `appModel` rather than
        // touching `configStore` directly — `AppModel` stays the single
        // owner of `AppConfig`, so `app.config` can never go stale behind
        // its back.
        _builder = State(initialValue: BuilderModel(
            scanner: ScanService(),
            toasts: toasts,
            templateLister: cli,
            launcher: TerminalLauncher(commandRunner: runner),
            clipboard: SystemClipboard(),
            persistTemplate: { [appModel] template in
                await appModel.update { $0.defaultTemplate = template }
            },
            mutateConfig: { [appModel] transform in
                await appModel.update(transform)
            },
            revealer: SystemFinder()
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(builder)
                .environment(sandboxes)
                .environment(toasts)
                .task {
                    await app.load()
                    // The Settings sheet can change `sbxPath` at runtime —
                    // pick it up here too, in case it changed on disk since
                    // the synchronous load in `init()` (same value
                    // otherwise — no re-resolve).
                    await locator.updateConfiguredPath(app.config.sbxPath)
                    appDelegate.onTerminate = { await app.flush() }
                    builder.adopt(config: app.config)
                    sandboxes.adopt(config: app.config)
                    builder.scan(
                        root: app.config.rootPath,
                        maxDepth: app.config.maxDepth,
                        ignoreFolders: Set(app.config.ignoreFolders)
                    )
                    // Last: can block up to 5s if `sbx` is missing/unresponsive
                    // (SbxCLI.listTemplates's own timeout), so it must not
                    // delay the scan or the config adoption above it.
                    await builder.loadTemplates()
                    // After templates for the same reason: the shell-probe
                    // fallback inside `resolvedPath` can take up to 2s, and
                    // the banner it drives must never delay first paint.
                    await app.checkSbxAvailability()
                }
        }
        Settings {
            SettingsView(locator: locator)
                .environment(app)
        }
        // Matches the Electron window (electron-main.mjs: 1280×860, min
        // 900×560). `.contentMinSize`, not `.contentSize` — the split view
        // must stay freely resizable.
        .defaultSize(width: 1280, height: 860)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(app: app, builder: builder, sandboxes: sandboxes)
        }
    }
}
