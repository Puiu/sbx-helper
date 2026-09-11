// Ports src/electron/public/app.js's sandboxes tab (785-1123) plus
// server.mjs's apiSandboxRun/apiSandboxRemove persistence semantics
// (388-414, 357-377).
import Testing
import Foundation
import SbxKit
import SbxServices
@testable import SbxAppCore

/// `AppModel`-owned config behind the `mutateConfig` closure — the same
/// shape `BuilderModel`'s tests use via `PersistedTemplateRecorder`, but
/// here the assertions read the resulting `sandboxArgs` map back.
private final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var config: AppConfig

    init(sandboxArgs: [String: String] = [:]) {
        var base = defaultConfig()
        base.sandboxArgs = sandboxArgs
        config = base
    }

    func mutate(_ transform: @escaping @Sendable (inout AppConfig) -> Void) {
        lock.withLock { transform(&config) }
    }

    var sandboxArgs: [String: String] {
        lock.withLock { config.sandboxArgs }
    }
}

@MainActor
struct SandboxesModelTests {
    private func runningSandbox(name: String = "web", agent: String = "claude") -> Sandbox {
        Sandbox(name: name, id: "id-\(name)", agent: agent, status: "running", workspaces: ["/repos/a"], ports: [])
    }

    private func model(
        store: StubSandboxStore = StubSandboxStore(),
        launcher: StubLauncher = StubLauncher(),
        toasts: ToastCenter = ToastCenter(),
        box: ConfigBox = ConfigBox()
    ) -> SandboxesModel {
        SandboxesModel(
            lister: store,
            controller: store,
            policies: store,
            launcher: launcher,
            toasts: toasts,
            mutateConfig: { [box] transform in box.mutate(transform) }
        )
    }

    private func modelWithList(
        _ sandboxes: [Sandbox],
        store: StubSandboxStore = StubSandboxStore(),
        box: ConfigBox = ConfigBox(),
        toasts: ToastCenter = ToastCenter(),
        launcher: StubLauncher = StubLauncher()
    ) async -> (SandboxesModel, StubSandboxStore) {
        store.listResult = .success(sandboxes)
        let m = model(store: store, launcher: launcher, toasts: toasts, box: box)
        var config = defaultConfig()
        config.sandboxArgs = box.sandboxArgs
        m.adopt(config: config)
        await m.fetch()
        return (m, store)
    }

    @Test
    func fetchStoresTheListAndMarksItLoaded() async {
        let (m, _) = await modelWithList([runningSandbox(), runningSandbox(name: "api")])

        #expect(m.sandboxes.map(\.name) == ["web", "api"])
        #expect(m.sandboxesLoaded == true)
        #expect(m.sandboxesError == nil)
    }

    @Test
    func fetchFailureEmptiesTheListAndRecordsTheError() async {
        let store = StubSandboxStore()
        store.listResult = .failure(.infrastructure("sbx ls failed."))
        let m = model(store: store)

        await m.fetch()

        #expect(m.sandboxes.isEmpty)
        #expect(m.sandboxesLoaded == true)
        #expect(m.sandboxesError == "sbx ls failed.")
    }

    @Test
    func refreshClearsASelectionThatNoLongerExists() async {
        let store = StubSandboxStore()
        store.listResult = .success([runningSandbox()])
        let m = model(store: store)
        await m.fetch()
        m.select("web")

        store.listResult = .success([])
        await m.fetch()

        #expect(m.selectedName == nil)
        #expect(m.selectedSandbox == nil)
    }

    @Test
    func refreshKeepsASelectionThatStillExists() async {
        let (m, store) = await modelWithList([runningSandbox()])
        m.select("web")

        store.listResult = .success([runningSandbox()])
        await m.fetch()

        #expect(m.selectedName == "web")
        #expect(m.selectedSandbox?.agent == "claude")
    }

    @Test
    func draftPrefersTheStoredSandboxArgsOverTheAgentDefault() async {
        let box = ConfigBox(sandboxArgs: ["web": "--model sonnet"])
        let (m, _) = await modelWithList([runningSandbox()], box: box)
        m.select("web")

        #expect(m.draftText(for: runningSandbox()) == "--model sonnet")
    }

    @Test
    func draftFallsBackToTheAgentDefaultFormatted() async {
        let (m, _) = await modelWithList([runningSandbox(), runningSandbox(name: "other", agent: "opencode")])

        #expect(m.draftText(for: runningSandbox()) == "--model opusplan")
        #expect(m.draftText(for: runningSandbox(name: "other", agent: "opencode")) == "")
    }

    @Test
    func typedDraftSurvivesSelectAwayAndBack() async {
        let (m, _) = await modelWithList([runningSandbox(), runningSandbox(name: "api")])
        m.select("web")
        m.setDraft("--model sonnet --verbose", for: "web")

        m.select("api")
        m.select("web")

        #expect(m.draftText(for: runningSandbox()) == "--model sonnet --verbose")
    }

    @Test
    func previewRendersRunExistingArgv() async {
        let (m, _) = await modelWithList([runningSandbox()])
        m.select("web")

        guard case .ready(let display) = m.commandPreview else {
            Issue.record("expected .ready")
            return
        }
        #expect(display == "sbx run --name web -- --model opusplan")
        #expect(m.canRun == true)
    }

    @Test
    func previewOmitsTheSeparatorWhenTheDraftIsEmpty() async {
        let (m, _) = await modelWithList([runningSandbox()])
        m.select("web")
        m.setDraft("", for: "web")

        guard case .ready(let display) = m.commandPreview else {
            Issue.record("expected .ready")
            return
        }
        #expect(display == "sbx run --name web")
    }

    @Test
    func previewReportsValidationErrorsAndDisablesRun() async {
        let (m, _) = await modelWithList([runningSandbox()])
        m.select("web")
        m.setDraft(Array(repeating: "x", count: 33).joined(separator: " "), for: "web")

        guard case .unavailable(let message) = m.commandPreview else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(message == "Too many agent-argument tokens (max 32).")
        #expect(m.canRun == false)
    }

    @Test
    func stopIsOnlyEnabledForRunningSandboxes() async {
        let stopped = Sandbox(name: "old", id: "id-old", agent: "claude", status: "stopped", workspaces: [], ports: [])
        let (m, _) = await modelWithList([runningSandbox(), stopped])

        m.select("web")
        #expect(m.canStop == true)

        m.select("old")
        #expect(m.canStop == false)
    }

    @Test
    func runPersistsTheFormattedArgsEvenWhenTheLaunchFails() async {
        let box = ConfigBox()
        let launcher = StubLauncher(result: LaunchResult(ok: false, method: nil, error: "no terminal"))
        let toasts = ToastCenter()
        let store = StubSandboxStore()
        store.runExistingResult = .success(["sbx", "run", "--name", "web", "--", "--model", "opusplan"])
        let (m, _) = await modelWithList([runningSandbox()], store: store, box: box, toasts: toasts, launcher: launcher)
        m.select("web")

        await m.run()

        #expect(box.sandboxArgs["web"] == "--model opusplan")
        #expect(toasts.current?.message == "no terminal")
        #expect(toasts.current?.isError == true)
    }

    @Test
    func runLaunchesTheArgvFromRunExistingAndToasts() async {
        let launcher = StubLauncher()
        let toasts = ToastCenter()
        let store = StubSandboxStore()
        let argv = ["sbx", "run", "--name", "web", "--", "--model", "opusplan"]
        store.runExistingResult = .success(argv)
        let (m, _) = await modelWithList([runningSandbox()], store: store, toasts: toasts, launcher: launcher)
        m.select("web")

        await m.run()

        #expect(launcher.calls == [argv])
        #expect(store.runExistingArgs.count == 1)
        #expect(store.runExistingArgs[0].agentArgs == ["--model", "opusplan"])
        #expect(toasts.current?.message == "Launched in a new terminal window.")
        #expect(toasts.current?.isError == false)
    }

    @Test
    func runWithAnEmptyDraftDeletesTheStoredArgsKey() async {
        let box = ConfigBox(sandboxArgs: ["web": "--model sonnet"])
        let store = StubSandboxStore()
        store.runExistingResult = .success(["sbx", "run", "--name", "web"])
        let (m, _) = await modelWithList([runningSandbox()], store: store, box: box)
        m.select("web")
        m.setDraft("", for: "web")

        await m.run()

        #expect(box.sandboxArgs["web"] == nil)
    }

    @Test
    func runWithAnInvalidDraftToastsAndNeverReachesTheController() async {
        let store = StubSandboxStore()
        let launcher = StubLauncher()
        let toasts = ToastCenter()
        let (m, _) = await modelWithList([runningSandbox()], store: store, toasts: toasts, launcher: launcher)
        m.select("web")
        m.setDraft(Array(repeating: "x", count: 33).joined(separator: " "), for: "web")

        await m.run()

        #expect(toasts.current?.message == "Too many agent-argument tokens (max 32).")
        #expect(toasts.current?.isError == true)
        #expect(store.callCount("runExisting") == 0)
        #expect(launcher.calls.isEmpty)
    }

    @Test
    func runAgainstAnUnknownSandboxToastsAndNeverLaunches() async {
        // The stale-selection race `requireKnownSandbox` exists for: listed
        // and selected, then gone by the time Run is pressed.
        let store = StubSandboxStore()
        let launcher = StubLauncher()
        let toasts = ToastCenter()
        let (m, _) = await modelWithList([runningSandbox(name: "ghost")], store: store, toasts: toasts, launcher: launcher)
        m.select("ghost")
        store.runExistingResult = .failure(.unknownSandbox("ghost"))

        await m.run()

        #expect(toasts.current?.message == "Unknown sandbox: ghost")
        #expect(toasts.current?.isError == true)
        #expect(launcher.calls.isEmpty)
    }

    @Test
    func stopSuccessToastsAndRefreshesTheList() async {
        let toasts = ToastCenter()
        let store = StubSandboxStore()
        let (m, _) = await modelWithList([runningSandbox()], store: store, toasts: toasts)
        m.select("web")

        await m.stop()

        #expect(toasts.current?.message == "Stopped web.")
        #expect(toasts.current?.isError == false)
        #expect(store.callCount("stop") == 1)
        #expect(store.callCount("list") == 2)
    }

    @Test
    func stopFailureToastsAndDoesNotRefresh() async {
        let store = StubSandboxStore()
        store.stopResult = .failure(.commandFailed("boom"))
        let toasts = ToastCenter()
        let (m, _) = await modelWithList([runningSandbox()], store: store, toasts: toasts)
        m.select("web")

        await m.stop()

        #expect(toasts.current?.message == "boom")
        #expect(toasts.current?.isError == true)
        #expect(store.callCount("list") == 1)
    }

    @Test
    func removeSuccessClearsSelectionDraftAndStoredArgs() async {
        let box = ConfigBox(sandboxArgs: ["web": "--model sonnet"])
        let toasts = ToastCenter()
        let store = StubSandboxStore()
        store.listResult = .success([runningSandbox()])
        let m = model(store: store, toasts: toasts, box: box)
        var config = defaultConfig()
        config.sandboxArgs = box.sandboxArgs
        m.adopt(config: config)
        await m.fetch()
        m.select("web")
        m.setDraft("--model sonnet", for: "web")
        m.requestDelete()
        #expect(m.showsDeleteConfirm == true)

        store.listResult = .success([])
        await m.confirmRemove()

        #expect(m.selectedName == nil)
        #expect(m.draftText(for: runningSandbox()) == "--model opusplan")
        #expect(box.sandboxArgs["web"] == nil)
        #expect(toasts.current?.message == "Deleted web.")
        #expect(m.showsDeleteConfirm == false)
        #expect(store.callCount("remove") == 1)
    }

    @Test
    func removeFailureKeepsTheConfirmOpenAndToasts() async {
        let store = StubSandboxStore()
        store.removeResult = .failure(.commandFailed("boom"))
        let toasts = ToastCenter()
        let (m, _) = await modelWithList([runningSandbox()], store: store, toasts: toasts)
        m.select("web")
        m.requestDelete()

        await m.confirmRemove()

        #expect(toasts.current?.message == "boom")
        #expect(toasts.current?.isError == true)
        #expect(m.showsDeleteConfirm == true)
        #expect(m.selectedName == "web")
    }

    @Test
    func isBusyIsTrueDuringTheRunAndFalseAfter() async {
        let launcher = StubLauncher()
        launcher.gate()
        let store = StubSandboxStore()
        store.runExistingResult = .success(["sbx", "run", "--name", "web"])
        let (m, _) = await modelWithList([runningSandbox()], store: store, launcher: launcher)
        m.select("web")
        m.setDraft("", for: "web")

        let runTask = Task { await m.run() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(m.isBusy == true)
        #expect(m.canRun == false)
        #expect(m.canStop == false)

        launcher.release()
        await runTask.value

        #expect(m.isBusy == false)
    }
}
