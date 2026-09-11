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

    init() {
        let configPath = resolveConfigPath(
            environment: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory()
        )
        let configStore = ConfigStore(path: configPath)

        // `ToolLocator` wants `config.sbxPath`, but `config` itself isn't
        // available until the async `app.load()` runs. Reading it here via
        // the same synchronous `loadConfig` that `ConfigStore` uses
        // internally avoids deferring the whole service graph into `.task`
        // for the sake of one field.
        let sbxPath = loadConfig(configPath).config.sbxPath
        let runner = ProcessRunner()
        let locator = ToolLocator(
            commandRunner: runner,
            environment: ProcessInfo.processInfo.environment,
            configuredPath: sbxPath
        )
        let cli = SbxCLI(commandRunner: runner, toolLocator: locator)

        let toasts = ToastCenter()
        let appModel = AppModel(configStore: configStore)
        _toasts = State(initialValue: toasts)
        _app = State(initialValue: appModel)
        let terminalLauncher = TerminalLauncher(commandRunner: runner)
        _sandboxes = State(initialValue: SandboxesModel(
            lister: cli,
            controller: cli,
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
                }
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
