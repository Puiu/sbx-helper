// Ports src/electron/public/app.js's policy scope labels (1009-1011) and
// summary line (993-995).
import Testing
import SbxKit

struct PolicyDisplayTests {
    private func rule(scoped: Bool, origin: String, decision: String = "allow") -> PolicyRule {
        PolicyRule(
            id: "id", name: "n", decision: decision, resources: ["example.com"],
            scope: scoped ? "sandbox:web" : "global", origin: origin, status: "",
            sandboxScoped: scoped, removable: scoped
        )
    }

    @Test
    func scopedRuleLabelsThisSandbox() {
        #expect(rule(scoped: true, origin: "sandbox").scopeLabel == "this sandbox")
    }

    @Test
    func unscopedRuleWithScopedOriginLabelsKit() {
        #expect(rule(scoped: false, origin: "scoped").scopeLabel == "kit")
    }

    @Test
    func unscopedRuleWithOtherOriginLabelsGlobal() {
        #expect(rule(scoped: false, origin: "global").scopeLabel == "global")
    }

    @Test
    func summaryCountsRulesScopedAndDeny() {
        let rules = [
            rule(scoped: true, origin: "sandbox", decision: "allow"),
            rule(scoped: false, origin: "global", decision: "deny"),
        ]
        #expect(policySummary(rules) == "2 rules apply · 1 scoped to this sandbox · 1 deny")
    }

    @Test
    func summaryUsesSingularApplies() {
        #expect(policySummary([rule(scoped: true, origin: "sandbox")]) == "1 rule applies · 1 scoped to this sandbox · 0 deny")
    }
}
