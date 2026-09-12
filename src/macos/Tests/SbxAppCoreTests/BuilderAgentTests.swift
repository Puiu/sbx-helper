import Foundation
import Testing
import SbxKit
import SbxServices
@testable import SbxAppCore

/// Records values a `@Sendable` `persistAgent` closure hands it, across
/// actor-boundary calls.
private final class PersistedAgentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func record(_ value: String) {
        lock.withLock { values.append(value) }
    }

    var recorded: [String] {
        lock.withLock { values }
    }
}

@MainActor
struct BuilderAgentTests {
    private func model(
        templates: [String] = [],
        persistAgent: (@Sendable (String) async -> Void)? = nil
    ) -> (BuilderModel, StubTemplateLister, PersistedAgentRecorder) {
        let lister = StubTemplateLister(result: templates)
        let recorder = PersistedAgentRecorder()
        let model = BuilderModel(
            scanner: StubScanner(),
            toasts: ToastCenter(),
            templateLister: lister,
            launcher: StubLauncher(),
            clipboard: StubClipboard(),
            persistTemplate: { _ in },
            persistAgent: persistAgent ?? { recorder.record($0) }
        )
        return (model, lister, recorder)
    }

    @Test("setAgent updates the agent and persists it")
    func setAgentPersists() async {
        let (model, _, recorder) = model()
        var config = defaultConfig()
        config.agent = "claude"
        model.adopt(config: config)

        await model.setAgent("opencode")

        #expect(model.agent == "opencode")
        #expect(recorder.recorded == ["opencode"])
    }

    @Test("commitTemplate auto-selects the agent named in the template")
    func commitTemplateAutoSelectsAgent() async {
        let (model, _, recorder) = model()
        var config = defaultConfig()
        config.agent = "claude"
        config.defaultTemplate = "claude-sbx-dotnet10:v2"
        model.adopt(config: config)

        await model.commitTemplate("docker.io/docker/sandbox-templates:opencode-docker")

        #expect(model.agent == "opencode")
        #expect(recorder.recorded == ["opencode"])
    }

    @Test("commitTemplate keeps the current agent when the template names none")
    func commitTemplateKeepsAgentWithoutMatch() async {
        let (model, _, recorder) = model()
        var config = defaultConfig()
        config.agent = "opencode"
        config.defaultTemplate = "claude-sbx-dotnet10:v2"
        model.adopt(config: config)
        await model.setAgent("opencode")
        let baseline = recorder.recorded.count

        await model.commitTemplate("my-neutral-template:v1")

        #expect(model.agent == "opencode")
        #expect(recorder.recorded.count == baseline)
    }

    // -- presets --

    private static func node(_ path: String, depth: Int) -> TreeNode {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return TreeNode(path: path, name: name, depth: depth, isGitRepo: false, unreadable: false)
    }

    private func presetHarness() -> (BuilderModel, AppModel, StubScanner) {
        let configDir = TempDirectory()
        let store = ConfigStore(
            path: (configDir.path as NSString).appendingPathComponent("sbx-helper.json"))
        let app = AppModel(configStore: store)
        let scanner = StubScanner()
        let builder = BuilderModel(
            scanner: scanner,
            toasts: ToastCenter(),
            templateLister: StubTemplateLister(),
            launcher: StubLauncher(),
            clipboard: StubClipboard(),
            persistTemplate: { [app] template in await app.update { $0.defaultTemplate = template } },
            persistAgent: { [app] agent in await app.update { $0.agent = agent } },
            mutateConfig: { [app] transform in await app.update(transform) },
            spinnerDelay: .milliseconds(10)
        )
        return (builder, app, scanner)
    }

    private func scanRoot(_ model: BuilderModel, _ scanner: StubScanner, root: String) async {
        scanner.setResult(
            ScannedTree(nodes: [Self.node(root, depth: 0), Self.node(root + "/A", depth: 1)]),
            for: root)
        scanner.release(root)
        model.scan(root: root, maxDepth: 3, ignoreFolders: [])
        await model.quiesce()
    }

    @Test("savePreset stores the current agent")
    func savePresetStoresAgent() async {
        let (model, app, scanner) = presetHarness()
        await app.load()
        await scanRoot(model, scanner, root: "/R")
        model.template = "tpl"
        await model.setAgent("opencode")
        model.setSelection("/R/A", .editable)

        let error = await model.savePreset(name: "p", existingPresets: [])

        #expect(error == nil)
        #expect(app.config.presets.count == 1)
        #expect(app.config.presets[0].agent == "opencode")
    }

    @Test("loadPreset restores the stored agent")
    func loadPresetRestoresAgent() async {
        let (model, _, scanner) = presetHarness()
        await scanRoot(model, scanner, root: "/R")
        await model.setAgent("claude")
        let preset = Preset(
            name: "p", rootPath: "/R", template: "t2", sandboxName: nil,
            clone: false, editable: ["A"], readOnly: [], agent: "opencode"
        )

        await model.loadPreset(preset, maxDepth: 3, ignoreFolders: [])

        #expect(model.agent == "opencode")
    }

    @Test("adopt falls back to the default agent for a blank config value")
    func adoptFallsBackForBlankAgent() {
        let (model, _, _) = model()
        var config = defaultConfig()
        config.agent = "   "

        model.adopt(config: config)

        #expect(model.agent == defaultConfig().agent)
    }

    @Test("adopt trims a padded config agent")
    func adoptTrimsAgent() {
        let (model, _, _) = model()
        var config = defaultConfig()
        config.agent = "  opencode  "

        model.adopt(config: config)

        #expect(model.agent == "opencode")
    }

    @Test("run persists the agent alongside the template")
    func runPersistsAgent() async {
        let launcher = StubLauncher()
        let recorder = PersistedAgentRecorder()
        let model = BuilderModel(
            scanner: StubScanner(),
            toasts: ToastCenter(),
            templateLister: StubTemplateLister(),
            launcher: launcher,
            clipboard: StubClipboard(),
            persistTemplate: { _ in },
            persistAgent: { recorder.record($0) },
            pathExists: { _ in true }
        )
        var config = defaultConfig()
        config.agent = "opencode"
        config.defaultTemplate = "tpl:v1"
        model.adopt(config: config)
        model.setSelection("/root/A", .editable)

        await model.run()

        #expect(recorder.recorded == ["opencode"])
    }

    @Test("loadPreset with a legacy agent-less preset keeps the current agent")
    func loadPresetWithoutAgentKeepsCurrent() async {
        let (model, _, scanner) = presetHarness()
        await scanRoot(model, scanner, root: "/R")
        await model.setAgent("opencode")
        let preset = Preset(
            name: "p", rootPath: "/R", template: "t2", sandboxName: nil,
            clone: false, editable: ["A"], readOnly: []
        )

        await model.loadPreset(preset, maxDepth: 3, ignoreFolders: [])

        #expect(model.agent == "opencode")
    }
}
