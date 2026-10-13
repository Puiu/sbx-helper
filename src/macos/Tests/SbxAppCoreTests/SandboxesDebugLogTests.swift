// Covers the Sandboxes tab's live "sbx commands" debug section wiring:
// `fetch()` snapshots the debugger's invocation log into `debugLog`, and
// a model built without a debugger keeps an empty log.
import Testing
import Foundation
import SbxKit
import SbxServices
@testable import SbxAppCore

@MainActor
struct SandboxesDebugLogTests {
    private final class StubDebugger: SandboxDebugging, @unchecked Sendable {
        var entries: [SbxInvocation] = []
        func recentInvocations() async -> [SbxInvocation] { entries }
    }

    private func model(store: StubSandboxStore, debugger: (any SandboxDebugging)? = nil) -> SandboxesModel {
        SandboxesModel(
            lister: store,
            controller: store,
            policies: store,
            launcher: StubLauncher(),
            toasts: ToastCenter(),
            debugger: debugger,
            mutateConfig: { _ in }
        )
    }

    @Test
    func fetchSnapshotsTheInvocationLog() async {
        let store = StubSandboxStore()
        store.listResult = .success([])
        let debugger = StubDebugger()
        debugger.entries = [
            SbxInvocation(id: 0, command: "sbx ls --json", ok: true, exitCode: 0, stdout: "[]", stderr: ""),
        ]
        let m = model(store: store, debugger: debugger)
        #expect(m.debugLog == [])
        await m.fetch()
        #expect(m.debugLog.count == 1)
        #expect(m.debugLog[0].command == "sbx ls --json")
    }

    @Test
    func fetchFailureStillSnapshotsTheLog() async {
        let store = StubSandboxStore()
        store.listResult = .failure(.infrastructure("Could not parse sbx ls output: boom"))
        let debugger = StubDebugger()
        debugger.entries = [
            SbxInvocation(id: 0, command: "sbx ls --json", ok: true, exitCode: 0, stdout: "???", stderr: ""),
        ]
        let m = model(store: store, debugger: debugger)
        await m.fetch()
        #expect(m.sandboxesError != nil)
        #expect(m.debugLog.count == 1)
    }

    @Test
    func debugLogStaysEmptyWithoutADebugger() async {
        let store = StubSandboxStore()
        store.listResult = .success([])
        let m = model(store: store)
        await m.fetch()
        #expect(m.debugLog == [])
    }
}
