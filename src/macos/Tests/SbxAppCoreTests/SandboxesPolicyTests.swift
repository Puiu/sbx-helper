// Ports src/electron/public/app.js's policy pane (fetchPolicies 829-841,
// renderPolicies 977-1038, doPolicyAdd 1125-1164, doPolicyRemove 1166-1180)
// plus server.mjs's apiSandboxPolicyAdd/apiSandboxPolicyRemove (416-469).
import Testing
import Foundation
import SbxKit
import SbxServices
@testable import SbxAppCore

@MainActor
struct SandboxesPolicyTests {
    private func runningSandbox(name: String = "web", agent: String = "claude") -> Sandbox {
        Sandbox(name: name, id: "id-\(name)", agent: agent, status: "running", workspaces: ["/repos/a"], ports: [])
    }

    private func policyRule(
        id: String, scoped: Bool, decision: String = "allow", resources: [String] = ["example.com"]
    ) -> PolicyRule {
        PolicyRule(
            id: id, name: id, decision: decision, resources: resources,
            scope: scoped ? "sandbox:web" : "global",
            origin: scoped ? "sandbox" : "global", status: "",
            sandboxScoped: scoped, removable: scoped
        )
    }

    private func model(
        store: StubSandboxStore = StubSandboxStore(),
        toasts: ToastCenter = ToastCenter()
    ) -> SandboxesModel {
        SandboxesModel(
            lister: store,
            controller: store,
            policies: store,
            launcher: StubLauncher(),
            toasts: toasts,
            mutateConfig: { _ in }
        )
    }

    private func modelWithList(
        _ sandboxes: [Sandbox],
        store: StubSandboxStore = StubSandboxStore(),
        toasts: ToastCenter = ToastCenter()
    ) async -> (SandboxesModel, StubSandboxStore) {
        store.listResult = .success(sandboxes)
        let m = model(store: store, toasts: toasts)
        m.adopt(config: defaultConfig())
        await m.fetch()
        return (m, store)
    }

    @Test
    func fetchPoliciesStoresRulesAndMarksPoliciesFor() async {
        let scoped = policyRule(id: "r1", scoped: true)
        let store = StubSandboxStore()
        store.listPolicyResult = .success([scoped, policyRule(id: "g1", scoped: false)])
        let (m, _) = await modelWithList([runningSandbox()], store: store)
        m.select("web")

        await m.fetchPolicies()

        #expect(m.policyRules.map(\.id) == ["r1", "g1"])
        #expect(m.policiesFor == "web")
        #expect(m.isPolicyLoading == false)
    }

    @Test
    func fetchPoliciesWithNoSelectionDoesNothing() async {
        let store = StubSandboxStore()
        let toasts = ToastCenter()
        let (m, _) = await modelWithList([runningSandbox()], store: store, toasts: toasts)

        await m.fetchPolicies()

        #expect(store.callCount("listPolicy") == 0)
        #expect(toasts.current == nil)
    }

    @Test
    func fetchPoliciesDiscardsStaleResults() async {
        let ruleB = policyRule(id: "rB", scoped: true)
        let store = StubSandboxStore()
        store.listPolicyResult = .success([policyRule(id: "rA", scoped: true)])
        store.gatePolicy()
        let (m, _) = await modelWithList(
            [runningSandbox(), runningSandbox(name: "api")], store: store
        )
        m.select("web")
        let gated = Task { await m.fetchPolicies() }
        while store.callCount("listPolicy") == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        m.select("api") // bumps the generation and clears the display state
        store.releasePolicy()
        await gated.value

        #expect(m.policyRules.isEmpty)
        #expect(m.policiesFor == nil)

        store.listPolicyResult = .success([ruleB])
        await m.fetchPolicies()

        #expect(m.policiesFor == "api")
        #expect(m.policyRules == [ruleB])
    }

    @Test
    func fetchPoliciesFailureToastsButDoesNotStickOnLoading() async {
        let store = StubSandboxStore()
        store.listPolicyResult = .failure(.infrastructure("sbx policy ls failed."))
        let toasts = ToastCenter()
        let (m, _) = await modelWithList([runningSandbox()], store: store, toasts: toasts)
        m.select("web")

        await m.fetchPolicies()

        #expect(toasts.current?.message == "sbx policy ls failed.")
        #expect(toasts.current?.isError == true)
        #expect(m.policiesFor == "web")
        #expect(m.policySummaryText == "0 rules apply · 0 scoped to this sandbox · 0 deny")
    }

    @Test
    func summaryShowsLoadingUntilPoliciesCatchUp() async {
        let store = StubSandboxStore()
        store.listPolicyResult = .success([policyRule(id: "r1", scoped: true)])
        let (m, _) = await modelWithList([runningSandbox()], store: store)
        m.select("web")

        #expect(m.policySummaryText == "Loading…")

        await m.fetchPolicies()

        #expect(m.policySummaryText == "1 rule applies · 1 scoped to this sandbox · 0 deny")
    }

    @Test
    func listRefreshThatClearsSelectionAlsoClearsPolicyState() async {
        let store = StubSandboxStore()
        store.listPolicyResult = .success([policyRule(id: "r1", scoped: true)])
        let (m, _) = await modelWithList([runningSandbox()], store: store)
        m.select("web")
        await m.fetchPolicies()
        #expect(m.policiesFor == "web")

        store.listResult = .success([])
        await m.fetch()

        #expect(m.policyRules.isEmpty)
        #expect(m.policiesFor == nil)
    }

    @Test
    func addPolicyWithEmptyInputShowsInlineErrorWithoutCallingController() async {
        let store = StubSandboxStore()
        let (m, _) = await modelWithList([runningSandbox()], store: store)
        m.select("web")
        m.policyInput = "  ,  "

        await m.addPolicy()

        #expect(m.policyError == "Enter at least one resource.")
        #expect(store.callCount("addPolicy") == 0)
    }

    @Test
    func addPolicyWithTooManyResourcesShowsInlineError() async {
        let store = StubSandboxStore()
        let (m, _) = await modelWithList([runningSandbox()], store: store)
        m.select("web")
        m.policyInput = Array(repeating: "a.com", count: 65).joined(separator: ",")

        await m.addPolicy()

        #expect(m.policyError == "Too many resources at once (max 64) — split them into multiple additions.")
        #expect(store.callCount("addPolicy") == 0)
    }

    @Test
    func addPolicyWithInvalidResourceNamesIt() async {
        let store = StubSandboxStore()
        let (m, _) = await modelWithList([runningSandbox()], store: store)
        m.select("web")
        m.policyInput = "example.com, -flag"

        await m.addPolicy()

        #expect(m.policyError == "Not a valid resource: -flag")
        #expect(store.callCount("addPolicy") == 0)
    }

    @Test
    func addPolicySuccessClearsInputStoresRulesAndToasts() async {
        let added = policyRule(id: "r2", scoped: true, resources: ["example.com"])
        let store = StubSandboxStore()
        store.addPolicyResult = .success([policyRule(id: "r1", scoped: true), added])
        let toasts = ToastCenter()
        let (m, _) = await modelWithList([runningSandbox()], store: store, toasts: toasts)
        m.select("web")
        m.policyDecision = .deny
        m.policyInput = "example.com"

        await m.addPolicy()

        #expect(store.addPolicyCalls.count == 1)
        #expect(store.addPolicyCalls[0].decision == .deny)
        #expect(store.addPolicyCalls[0].resources == ["example.com"])
        #expect(m.policyInput == "")
        #expect(m.policyError == nil)
        #expect(m.policyRules.map(\.id) == ["r1", "r2"])
        #expect(m.policiesFor == "web")
        #expect(toasts.current?.message == "Rule added.")
        #expect(toasts.current?.isError == false)
    }

    @Test
    func addPolicyFailureShowsInlineErrorAndKeepsInput() async {
        let store = StubSandboxStore()
        store.addPolicyResult = .failure(.commandFailed("denied by server"))
        let (m, _) = await modelWithList([runningSandbox()], store: store)
        m.select("web")
        m.policyInput = "example.com"

        await m.addPolicy()

        #expect(m.policyError == "denied by server")
        #expect(m.policyInput == "example.com")
    }

    @Test
    func removePolicySuccessRefreshesTheListAndToasts() async {
        let store = StubSandboxStore()
        store.listPolicyResult = .success([])
        let toasts = ToastCenter()
        let (m, _) = await modelWithList([runningSandbox()], store: store, toasts: toasts)
        m.select("web")
        await m.fetchPolicies()

        await m.removePolicy(policyRule(id: "r1", scoped: true))

        #expect(store.removePolicyCalls.count == 1)
        #expect(store.removePolicyCalls[0].ruleId == "r1")
        #expect(store.removePolicyCalls[0].resource == nil)
        #expect(store.callCount("listPolicy") == 2)
        #expect(toasts.current?.message == "Rule removed.")
        #expect(toasts.current?.isError == false)
    }

    @Test
    func removePolicyFailureToastsAnError() async {
        let store = StubSandboxStore()
        store.removePolicyResult = .failure(.ruleNotRemovable("g1"))
        let toasts = ToastCenter()
        let (m, _) = await modelWithList([runningSandbox()], store: store, toasts: toasts)
        m.select("web")

        await m.removePolicy(policyRule(id: "g1", scoped: false))

        #expect(toasts.current?.message == "That rule cannot be removed from here: g1")
        #expect(toasts.current?.isError == true)
    }
}
