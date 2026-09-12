// Ports src/electron/test/sandboxes.test.mjs (parseSandboxLs, parseNetworkRules
// describe blocks) and the formatPort tests from
// src/electron/test/sandbox-commands.test.mjs — formatPort's real home is
// Port.formatted here, alongside the rest of the type.
import Testing
@testable import SbxKit

@Suite("Port.formatted")
struct PortFormattedTests {
    @Test("formats a published port with an explicit host IP")
    func withHostIP() {
        let port = Port(hostIP: "127.0.0.1", hostPort: 8080, sandboxPort: 80, protocolName: "tcp")
        #expect(port.formatted == "127.0.0.1:8080->80/tcp")
    }

    @Test("formats a published port without a host IP")
    func withoutHostIP() {
        let port = Port(hostPort: 8080, sandboxPort: 80, protocolName: "tcp")
        #expect(port.formatted == "8080->80/tcp")
    }
}

@Suite("parseSandboxLs")
struct ParseSandboxLsTests {
    @Test("parses the sandboxes array from real sbx ls --json output")
    func parsesRealOutput() throws {
        let stdout = """
        {
          "sandboxes": [
            {
              "name": "24114-natt-sync-selskap",
              "id": "99ea36b1-c896-4371-9bec-35befe90e4e6",
              "agent": "claude",
              "status": "running",
              "workspaces": ["/Users/alexalbu/repos/nho/ForeningshubV2/NHO.0474.Federationhub.Api"]
            },
            {
              "name": "opencode-os-vitals",
              "id": "f1b82fae-05aa-46cd-9eb2-826471fa4724",
              "agent": "opencode",
              "status": "stopped",
              "workspaces": ["/Users/alexalbu/repos/my-apps/os-vitals"]
            }
          ]
        }
        """
        let sandboxes = try parseSandboxLs(stdout)
        #expect(sandboxes.count == 2)
        #expect(sandboxes[0].name == "24114-natt-sync-selskap")
        #expect(sandboxes[0].agent == "claude")
        #expect(sandboxes[0].status == "running")
        #expect(sandboxes[0].workspaces == ["/Users/alexalbu/repos/nho/ForeningshubV2/NHO.0474.Federationhub.Api"])
        #expect(sandboxes[0].ports == [])
    }

    @Test("preserves a ports array when present")
    func preservesPortsArray() throws {
        let stdout = """
        {"sandboxes": [{"name":"x","id":"abc","agent":"claude","status":"running","workspaces":[],
          "ports":[{"host_ip":"127.0.0.1","host_port":8080,"sandbox_port":80,"protocol":"tcp"}]}]}
        """
        let sandboxes = try parseSandboxLs(stdout)
        #expect(sandboxes[0].ports == [Port(hostIP: "127.0.0.1", hostPort: 8080, sandboxPort: 80, protocolName: "tcp")])
    }

    @Test("tolerates a missing sandboxes key")
    func toleratesMissingKey() throws {
        #expect(try parseSandboxLs("{}") == [])
    }

    @Test("throws a clean error on malformed JSON")
    func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) { try parseSandboxLs("not json") }
    }

    @Test("a malformed sandbox entry is dropped, the rest survive")
    func dropsMalformedEntry() throws {
        let stdout = """
        {"sandboxes": [
          {"name":"good","id":"1","agent":"claude","status":"running","workspaces":[]},
          "not-an-object",
          {"name":"also-good","id":"2","agent":"claude","status":"stopped","workspaces":[]}
        ]}
        """
        let sandboxes = try parseSandboxLs(stdout)
        #expect(sandboxes.map(\.name) == ["good", "also-good"])
    }
}

@Suite("parseNetworkRules")
struct ParseNetworkRulesTests {
    static let sampleStdout = """
    {"rules": [
      {"id":"default-ai-services","name":"default-ai-services","policy_id":"local-policy",
       "scope":"global","applies_to":"all","resource_type":"network","decision":"allow",
       "resources":["api.anthropic.com:443"],"origin":"local","layer":"local","status":"active","editable":true},
      {"id":"default-fs-read-allow-all","name":"default-fs-read-allow-all","policy_id":"local-policy",
       "scope":"global","applies_to":"all","resource_type":"filesystem:read","decision":"allow",
       "resources":["**"],"origin":"local","layer":"local","status":"active","editable":false},
      {"id":"a8ddb581-491b-406d-9b3b-40642d09ac1d","name":"kit:my-sandbox","policy_id":"cd983560-276b-4a96-853c-93d0b07c2a4d",
       "scope":"sandbox:my-sandbox","applies_to":"sandbox:my-sandbox","resource_type":"network","decision":"allow",
       "resources":["registry.example.com:443"],"origin":"scoped","layer":"local","status":"active","editable":false},
      {"id":"user-added-rule-id","name":"user-added-rule-id","policy_id":"local-policy",
       "scope":"sandbox:my-sandbox","applies_to":"sandbox:my-sandbox","resource_type":"network","decision":"deny",
       "resources":["ads.example.com"],"origin":"local","layer":"local","status":"active","editable":true}
    ]}
    """

    @Test("filters to network rules only")
    func filtersToNetworkOnly() throws {
        let rules = try parseNetworkRules(stdout: Self.sampleStdout, sandboxName: "my-sandbox")
        #expect(!rules.contains { $0.id == "default-fs-read-allow-all" })
    }

    @Test("marks a rule scoped to this sandbox as sandboxScoped")
    func marksSandboxScoped() throws {
        let rules = try parseNetworkRules(stdout: Self.sampleStdout, sandboxName: "my-sandbox")
        #expect(rules.first { $0.id == "user-added-rule-id" }?.sandboxScoped == true)
    }

    @Test("marks a global rule as not sandboxScoped")
    func marksGlobalNotScoped() throws {
        let rules = try parseNetworkRules(stdout: Self.sampleStdout, sandboxName: "my-sandbox")
        #expect(rules.first { $0.id == "default-ai-services" }?.sandboxScoped == false)
    }

    @Test("a sandbox-scoped, editable rule is removable")
    func scopedEditableIsRemovable() throws {
        let rules = try parseNetworkRules(stdout: Self.sampleStdout, sandboxName: "my-sandbox")
        #expect(rules.first { $0.id == "user-added-rule-id" }?.removable == true)
    }

    @Test("a sandbox-scoped but non-editable (kit) rule is not removable")
    func scopedNonEditableNotRemovable() throws {
        let rules = try parseNetworkRules(stdout: Self.sampleStdout, sandboxName: "my-sandbox")
        #expect(rules.first { $0.id == "a8ddb581-491b-406d-9b3b-40642d09ac1d" }?.removable == false)
    }

    @Test("a global rule is not removable regardless of editable")
    func globalNotRemovable() throws {
        let rules = try parseNetworkRules(stdout: Self.sampleStdout, sandboxName: "my-sandbox")
        #expect(rules.first { $0.id == "default-ai-services" }?.removable == false)
    }

    // Fail closed: a rule with no `editable` field at all must not be
    // treated as removable just because it isn't explicitly false.
    @Test("a sandbox-scoped rule with no editable field at all is not removable")
    func noEditableFieldNotRemovable() throws {
        let stdout = """
        {"rules": [{"id":"no-editable-field","name":"no-editable-field","policy_id":"local-policy",
          "scope":"sandbox:my-sandbox","applies_to":"sandbox:my-sandbox","resource_type":"network",
          "decision":"allow","resources":["a.com"],"origin":"local","layer":"local","status":"active"}]}
        """
        let rules = try parseNetworkRules(stdout: stdout, sandboxName: "my-sandbox")
        #expect(rules[0].removable == false)
    }

    // Fail closed again: without an id the removal lookup can never match,
    // so an id-less rule must not offer a × button that always fails.
    @Test("a sandbox-scoped, editable rule with an empty id is not removable")
    func emptyIdNotRemovable() throws {
        let stdout = """
        {"rules": [{"id":"","name":"orphan","policy_id":"local-policy",
          "scope":"sandbox:my-sandbox","applies_to":"sandbox:my-sandbox","resource_type":"network",
          "decision":"allow","resources":["a.com"],"origin":"local","layer":"local","status":"active","editable":true}]}
        """
        let rules = try parseNetworkRules(stdout: stdout, sandboxName: "my-sandbox")
        #expect(rules[0].removable == false)
    }

    @Test("sorts sandbox-scoped rules before global rules")
    func sortsScopedFirst() throws {
        let rules = try parseNetworkRules(stdout: Self.sampleStdout, sandboxName: "my-sandbox")
        let firstGlobalIndex = rules.firstIndex { !$0.sandboxScoped }!
        let lastScopedIndex = rules.lastIndex { $0.sandboxScoped }!
        #expect(lastScopedIndex < firstGlobalIndex)
    }

    @Test("preserves within-group order (stable partition, not a sort)")
    func preservesWithinGroupOrder() throws {
        let rules = try parseNetworkRules(stdout: Self.sampleStdout, sandboxName: "my-sandbox")
        let scopedIDs = rules.filter(\.sandboxScoped).map(\.id)
        #expect(scopedIDs == ["a8ddb581-491b-406d-9b3b-40642d09ac1d", "user-added-rule-id"])
    }
}
