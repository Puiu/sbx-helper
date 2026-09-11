// Ports src/electron/public/app.js's doCopy (465-483) and doRun (485-515),
// plus server.mjs's apiRun pre-launch validation (231-274).
import Testing
import Foundation
import SbxKit
import SbxServices
@testable import SbxAppCore

@MainActor
struct BuilderLaunchTests {
    private func model(
        launcher: StubLauncher = StubLauncher(),
        clipboard: StubClipboard = StubClipboard(),
        pathExists: @escaping @Sendable (String) -> Bool = { _ in true },
        toasts: ToastCenter = ToastCenter()
    ) -> BuilderModel {
        BuilderModel(
            scanner: StubScanner(),
            toasts: toasts,
            templateLister: StubTemplateLister(),
            launcher: launcher,
            clipboard: clipboard,
            persistTemplate: { _ in },
            pathExists: pathExists
        )
    }

    @Test
    func copyPutsTheRenderedCommandOnTheClipboard() {
        let clipboard = StubClipboard()
        let model = model(clipboard: clipboard)
        model.template = "tpl"
        model.setSelection("/root/A", .editable)

        model.copyCommand()

        guard case .ready(let display) = model.commandPreview else {
            Issue.record("expected .ready")
            return
        }
        #expect(clipboard.written == [display])
    }

    @Test
    func copyRaisesTheCopiedToast() {
        let toasts = ToastCenter()
        let model = model(toasts: toasts)
        model.template = "tpl"
        model.setSelection("/root/A", .editable)

        model.copyCommand()

        #expect(toasts.current?.message == "Copied to clipboard.")
        #expect(toasts.current?.isError == false)
    }

    @Test
    func copyDoesNothingWhenThePreviewIsUnavailable() {
        let clipboard = StubClipboard()
        let toasts = ToastCenter()
        let model = model(clipboard: clipboard, toasts: toasts)

        model.copyCommand()

        #expect(clipboard.written.isEmpty)
        #expect(toasts.current == nil)
    }

    @Test
    func aFailedCopyRaisesAnErrorToast() {
        let clipboard = StubClipboard(succeeds: false)
        let toasts = ToastCenter()
        let model = model(clipboard: clipboard, toasts: toasts)
        model.template = "tpl"
        model.setSelection("/root/A", .editable)

        model.copyCommand()

        #expect(toasts.current?.isError == true)
    }

    @Test
    func runWithNoEditableSelectionRaisesItsOwnToastAndDoesNotLaunch() async {
        let launcher = StubLauncher()
        let toasts = ToastCenter()
        let model = model(launcher: launcher, toasts: toasts)

        await model.run()

        #expect(toasts.current?.message == "Select at least one editable folder first.")
        #expect(toasts.current?.isError == true)
        #expect(launcher.calls.isEmpty)
    }

    @Test
    func runRejectsARelativeWorkspacePathBeforeLaunching() async {
        let launcher = StubLauncher()
        let toasts = ToastCenter()
        let model = model(launcher: launcher, pathExists: { _ in true }, toasts: toasts)
        model.template = "tpl"
        model.setSelection("relative/path", .editable)

        await model.run()

        #expect(toasts.current?.message == "Every workspace path must be an absolute path.")
        #expect(launcher.calls.isEmpty)
    }

    @Test
    func runRejectsAMissingFolderAndNamesItInTheToast() async {
        let launcher = StubLauncher()
        let toasts = ToastCenter()
        let model = model(launcher: launcher, pathExists: { _ in false }, toasts: toasts)
        model.template = "tpl"
        model.setSelection("/gone", .editable)

        await model.run()

        #expect(toasts.current?.message == "Folder not found: /gone")
        #expect(launcher.calls.isEmpty)
    }

    @Test
    func runPassesTheFullArgvIncludingTheLeadingSbxToTheLauncher() async {
        let launcher = StubLauncher()
        let model = model(launcher: launcher)
        model.template = "tpl:v1"
        model.setSelection("/root/A", .editable)
        var config = defaultConfig()
        config.agent = "claude"
        model.adopt(config: config)

        await model.run()

        #expect(launcher.calls.count == 1)
        #expect(launcher.calls[0] == ["sbx", "run", "--template", "tpl:v1", "claude", "/root/A"])
    }

    @Test
    func runRaisesTheLaunchedToastOnSuccess() async {
        let launcher = StubLauncher(result: LaunchResult(ok: true, method: "iterm-applescript", error: nil))
        let toasts = ToastCenter()
        let model = model(launcher: launcher, toasts: toasts)
        model.template = "tpl"
        model.setSelection("/root/A", .editable)

        await model.run()

        #expect(toasts.current?.message == "Launched in a new terminal window.")
        #expect(toasts.current?.isError == false)
    }

    @Test
    func runSurfacesTheLaunchersErrorMessageOnFailure() async {
        let launcher = StubLauncher(result: LaunchResult(ok: false, method: nil, error: "iTerm not installed."))
        let toasts = ToastCenter()
        let model = model(launcher: launcher, toasts: toasts)
        model.template = "tpl"
        model.setSelection("/root/A", .editable)

        await model.run()

        #expect(toasts.current?.message == "iTerm not installed.")
        #expect(toasts.current?.isError == true)
    }

    @Test
    func runFallsBackToAGenericMessageWhenTheLauncherGivesNoReason() async {
        let launcher = StubLauncher(result: LaunchResult(ok: false, method: nil, error: nil))
        let toasts = ToastCenter()
        let model = model(launcher: launcher, toasts: toasts)
        model.template = "tpl"
        model.setSelection("/root/A", .editable)

        await model.run()

        #expect(toasts.current?.message == "Could not open a terminal window.")
    }

    @Test
    func runPersistsTheEffectiveTemplate() async {
        let recorder = PersistedTemplateRecorderForLaunch()
        let model = BuilderModel(
            scanner: StubScanner(),
            toasts: ToastCenter(),
            templateLister: StubTemplateLister(),
            launcher: StubLauncher(),
            clipboard: StubClipboard(),
            persistTemplate: { recorder.record($0) },
            pathExists: { _ in true }
        )
        model.template = "tpl:v1"
        model.setSelection("/root/A", .editable)

        await model.run()

        #expect(recorder.recorded == ["tpl:v1"])
    }

    @Test
    func isLaunchingIsTrueDuringTheLaunchAndFalseAfter() async {
        let launcher = StubLauncher()
        launcher.gate()
        let model = model(launcher: launcher)
        model.template = "tpl"
        model.setSelection("/root/A", .editable)

        let runTask = Task { await model.run() }
        // Give run() a chance to reach the launcher and set isLaunching.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.isLaunching == true)
        #expect(model.canRun == false)

        launcher.release()
        await runTask.value

        #expect(model.isLaunching == false)
    }

    @Test
    func isLaunchingIsClearedEvenWhenTheLaunchFails() async {
        let launcher = StubLauncher(result: LaunchResult(ok: false, method: nil, error: "boom"))
        let model = model(launcher: launcher)
        model.template = "tpl"
        model.setSelection("/root/A", .editable)

        await model.run()

        #expect(model.isLaunching == false)
    }
}

/// Same shape as `PersistedTemplateRecorder` in BuilderSettingsTests — kept
/// separate to avoid cross-file access-level friction for a `private` type.
private final class PersistedTemplateRecorderForLaunch: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func record(_ value: String) {
        lock.withLock { values.append(value) }
    }

    var recorded: [String] {
        lock.withLock { values }
    }
}
