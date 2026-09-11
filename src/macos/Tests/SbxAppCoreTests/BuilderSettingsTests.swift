// Ports src/electron/public/app.js's populateTemplateSelect (415-439) and
// the template/name/clone change handlers (1325-1351).
import Foundation
import Testing
import SbxKit
import SbxServices
@testable import SbxAppCore

/// Records values a `@Sendable` `persistTemplate` closure hands it, across
/// actor-boundary calls.
private final class PersistedTemplateRecorder: @unchecked Sendable {
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
struct BuilderSettingsTests {
    private func model(templates: [String] = []) -> (BuilderModel, StubTemplateLister) {
        let lister = StubTemplateLister(result: templates)
        let model = BuilderModel(
            scanner: StubScanner(),
            toasts: ToastCenter(),
            templateLister: lister,
            launcher: StubLauncher(),
            clipboard: StubClipboard(),
            persistTemplate: { _ in }
        )
        return (model, lister)
    }

    @Test
    func adoptTakesAgentAndDefaultTemplateFromConfig() {
        let (model, _) = model()
        var config = defaultConfig()
        config.agent = "claude"
        config.defaultTemplate = "claude-sbx-dotnet10:v2"

        model.adopt(config: config)

        #expect(model.agent == "claude")
        #expect(model.defaultTemplate == "claude-sbx-dotnet10:v2")
    }

    @Test
    func adoptSeedsTheTemplateWhenItIsStillEmpty() {
        let (model, _) = model()
        var config = defaultConfig()
        config.defaultTemplate = "claude-sbx-dotnet10:v2"

        model.adopt(config: config)

        #expect(model.template == "claude-sbx-dotnet10:v2")
    }

    @Test
    func adoptDoesNotOverwriteATemplateTheUserAlreadyChose() {
        let (model, _) = model()
        model.template = "custom:v1"
        var config = defaultConfig()
        config.defaultTemplate = "claude-sbx-dotnet10:v2"

        model.adopt(config: config)

        #expect(model.template == "custom:v1")
    }

    @Test
    func effectiveTemplateFallsBackToTheDefaultWhenUnset() {
        let (model, _) = model()
        var config = defaultConfig()
        config.defaultTemplate = "claude-sbx-dotnet10:v2"
        model.adopt(config: config)
        model.template = ""

        #expect(model.effectiveTemplate == "claude-sbx-dotnet10:v2")
    }

    @Test
    func templateOptionsPutTheDefaultFirst() async {
        let (model, _) = model(templates: ["a:v1", "b:v1"])
        var config = defaultConfig()
        config.defaultTemplate = "default:v1"
        model.adopt(config: config)
        await model.loadTemplates()

        #expect(model.templateOptions.first == "default:v1")
    }

    @Test
    func templateOptionsDeduplicateTheDefaultAgainstTheListedTemplates() async {
        let (model, _) = model(templates: ["shared:v1", "other:v1"])
        var config = defaultConfig()
        config.defaultTemplate = "shared:v1"
        model.adopt(config: config)
        await model.loadTemplates()

        #expect(model.templateOptions == ["shared:v1", "other:v1"])
    }

    @Test
    func templateOptionsAreNeverEmpty() async {
        let (model, _) = model(templates: [])
        var config = defaultConfig()
        config.defaultTemplate = "default:v1"
        model.adopt(config: config)
        await model.loadTemplates()

        #expect(model.templateOptions == ["default:v1"])
    }

    @Test
    func loadTemplatesStoresWhatTheListerReturns() async {
        let (model, _) = model(templates: ["a:v1", "b:v1"])
        await model.loadTemplates()
        #expect(model.templates == ["a:v1", "b:v1"])
    }

    @Test
    func aTemplateOnTheListIsNotConsideredCustom() {
        let (model, _) = model()
        var config = defaultConfig()
        config.defaultTemplate = "default:v1"
        model.adopt(config: config)

        #expect(model.usesCustomTemplate == false)
    }

    @Test
    func aTemplateOffTheListIsConsideredCustom() {
        let (model, _) = model()
        var config = defaultConfig()
        config.defaultTemplate = "default:v1"
        model.adopt(config: config)
        model.template = "something-else:v1"

        #expect(model.usesCustomTemplate == true)
    }

    @Test
    func commitTemplateTrimsWhitespace() async {
        let (model, _) = model()
        await model.commitTemplate("  custom:v1  ")
        #expect(model.template == "custom:v1")
    }

    @Test
    func commitTemplateFallsBackToTheDefaultForABlankValue() async {
        let (model, _) = model()
        var config = defaultConfig()
        config.defaultTemplate = "default:v1"
        model.adopt(config: config)

        await model.commitTemplate("   ")

        #expect(model.template == "default:v1")
    }

    @Test
    func commitTemplatePersistsTheEffectiveTemplate() async {
        let lister = StubTemplateLister()
        let recorder = PersistedTemplateRecorder()
        let model = BuilderModel(
            scanner: StubScanner(),
            toasts: ToastCenter(),
            templateLister: lister,
            launcher: StubLauncher(),
            clipboard: StubClipboard(),
            persistTemplate: { recorder.record($0) }
        )

        await model.commitTemplate("custom:v1")

        #expect(recorder.recorded == ["custom:v1"])
    }
}
