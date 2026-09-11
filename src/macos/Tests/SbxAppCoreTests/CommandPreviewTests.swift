// Ports src/electron/public/app.js's refreshCommand (360-392) — builds a
// RunSelection from the model's current state and reports either the
// rendered command or the single reachable error message.
import Testing
import SbxKit
@testable import SbxAppCore

@MainActor
struct CommandPreviewTests {
    private func model() -> BuilderModel {
        BuilderModel(
            scanner: StubScanner(),
            toasts: ToastCenter(),
            templateLister: StubTemplateLister(),
            launcher: StubLauncher(),
            clipboard: StubClipboard(),
            persistTemplate: { _ in }
        )
    }

    @Test
    func anEmptySelectionIsUnavailableWithTheNoEditableWorkspaceMessage() {
        let model = model()
        guard case .unavailable(let message) = model.commandPreview else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(message == "At least one editable workspace is required.")
    }

    @Test
    func aReadOnlyOnlySelectionIsAlsoUnavailable() {
        let model = model()
        model.setSelection("/root/A", .readOnly)
        guard case .unavailable(let message) = model.commandPreview else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(message == "At least one editable workspace is required.")
    }

    @Test
    func oneEditableFolderProducesTheFullCommand() {
        let model = model()
        var config = defaultConfig()
        config.agent = "claude"
        config.defaultTemplate = "claude-sbx-dotnet10:v2"
        model.adopt(config: config)
        model.setSelection("/path/to/NHO.0476.ConsentRegister.Web", .editable)
        model.setSelection("/path/to/NHO.AccessHub.Web", .readOnly)

        guard case .ready(let display) = model.commandPreview else {
            Issue.record("expected .ready")
            return
        }
        #expect(display == "sbx run --template claude-sbx-dotnet10:v2 claude /path/to/NHO.0476.ConsentRegister.Web /path/to/NHO.AccessHub.Web:ro")
    }

    @Test
    func theTemplateFlagComesFirstAfterRun() {
        let model = model()
        model.adopt(config: defaultConfig()) // agent == "claude"
        model.template = "my-template:v1"
        model.setSelection("/root/A", .editable)

        guard case .ready(let display) = model.commandPreview else {
            Issue.record("expected .ready")
            return
        }
        #expect(display == "sbx run --template my-template:v1 claude /root/A")
    }

    @Test
    func theSandboxNameIsEmittedTrimmedAndOmittedWhenBlank() {
        let model = model()
        model.adopt(config: defaultConfig()) // agent == "claude"
        model.template = "tpl"
        model.setSelection("/root/A", .editable)
        model.sandboxName = "   "
        guard case .ready(let blankDisplay) = model.commandPreview else {
            Issue.record("expected .ready")
            return
        }
        #expect(blankDisplay == "sbx run --template tpl claude /root/A")

        model.sandboxName = "  my-sandbox  "
        guard case .ready(let namedDisplay) = model.commandPreview else {
            Issue.record("expected .ready")
            return
        }
        #expect(namedDisplay == "sbx run --template tpl --name my-sandbox claude /root/A")
    }

    @Test
    func theCloneFlagIsEmittedAfterNameAndBeforeTheAgent() {
        let model = model()
        model.template = "tpl:v1"
        model.sandboxName = "my-sandbox"
        model.clone = true
        model.setSelection("/root/A", .editable)
        var config = defaultConfig()
        config.agent = "claude"
        model.adopt(config: config)

        guard case .ready(let display) = model.commandPreview else {
            Issue.record("expected .ready")
            return
        }
        #expect(display == "sbx run --template tpl:v1 --name my-sandbox --clone claude /root/A")
    }

    @Test
    func thePrimaryFolderComesFirstAmongTheWorkspaces() {
        let model = model()
        model.adopt(config: defaultConfig()) // agent == "claude"
        model.template = "tpl"
        model.setSelection("/root/B", .editable)
        model.setSelection("/root/A", .editable)
        model.setPrimary("/root/A")

        guard case .ready(let display) = model.commandPreview else {
            Issue.record("expected .ready")
            return
        }
        #expect(display == "sbx run --template tpl claude /root/A /root/B")
    }

    @Test
    func readOnlyPathsComeLastEachWithTheRoSuffix() {
        let model = model()
        model.adopt(config: defaultConfig()) // agent == "claude"
        model.template = "tpl"
        model.setSelection("/root/A", .editable)
        model.setSelection("/root/D", .readOnly)
        model.setSelection("/root/C", .readOnly)

        guard case .ready(let display) = model.commandPreview else {
            Issue.record("expected .ready")
            return
        }
        #expect(display == "sbx run --template tpl claude /root/A /root/C:ro /root/D:ro")
    }

    @Test
    func theRoSuffixStaysInsideTheQuotesForASpacedPath() {
        let model = model()
        model.adopt(config: defaultConfig()) // agent == "claude"
        model.template = "tpl"
        model.setSelection("/root/A", .editable)
        model.setSelection("/path/with space", .readOnly)

        guard case .ready(let display) = model.commandPreview else {
            Issue.record("expected .ready")
            return
        }
        #expect(display == "sbx run --template tpl claude /root/A '/path/with space:ro'")
    }

    @Test
    func theEffectiveTemplateIsUsedWhenTheFieldIsEmpty() {
        let model = model()
        var config = defaultConfig() // agent == "claude"
        config.defaultTemplate = "claude-sbx-dotnet10:v2"
        model.adopt(config: config)
        model.template = ""
        model.setSelection("/root/A", .editable)

        guard case .ready(let display) = model.commandPreview else {
            Issue.record("expected .ready")
            return
        }
        #expect(display == "sbx run --template claude-sbx-dotnet10:v2 claude /root/A")
    }

    @Test
    func copyAndRunAreUnavailableWhileThePreviewIsUnavailable() {
        let model = model()
        #expect(model.canCopy == false)
        #expect(model.canRun == false)
    }

    @Test
    func copyAndRunAreAvailableOnceThePreviewIsReady() {
        let model = model()
        model.template = "tpl"
        model.setSelection("/root/A", .editable)
        #expect(model.canCopy == true)
        #expect(model.canRun == true)
    }
}
