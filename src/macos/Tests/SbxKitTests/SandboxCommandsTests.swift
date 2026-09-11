// Ports src/electron/test/sandbox-commands.test.mjs (buildRunExistingArgs,
// buildStopArgs, buildRemoveArgs, buildPolicyAddArgs, buildPolicyRemoveArgs
// describe blocks).
import Testing
@testable import SbxKit

@Suite("buildRunExistingArgs")
struct BuildRunExistingArgsTests {
    @Test("includes the -- separator and agent args when args are given")
    func includesSeparatorWithArgs() throws {
        let args = try buildRunExistingArgs(name: "my-sandbox", agentArgs: ["--model", "opusplan"])
        #expect(args == ["sbx", "run", "--name", "my-sandbox", "--", "--model", "opusplan"])
    }

    @Test("omits the -- separator entirely when there are no agent args")
    func omitsSeparatorWithoutArgs() throws {
        let args = try buildRunExistingArgs(name: "my-sandbox", agentArgs: [])
        #expect(args == ["sbx", "run", "--name", "my-sandbox"])
    }

    @Test("throws when name is missing")
    func throwsWhenNameMissing() {
        #expect(throws: SbxKitError.sandboxNameRequired) {
            try buildRunExistingArgs(name: "", agentArgs: [])
        }
    }

    @Test("throws when agentArgs fails structural validation, e.g. a control character")
    func throwsOnInvalidAgentArgs() {
        #expect(throws: SbxKitError.agentArgControlCharacter) {
            try buildRunExistingArgs(name: "x", agentArgs: ["a\nb"])
        }
    }

    @Test("throws when agentArgs has too many tokens")
    func throwsWhenTooManyTokens() {
        let tooMany = (0...maxAgentArgTokens).map { "t\($0)" }
        #expect(throws: SbxKitError.tooManyAgentArgTokens(max: maxAgentArgTokens)) {
            try buildRunExistingArgs(name: "x", agentArgs: tooMany)
        }
    }
}

@Suite("buildStopArgs")
struct BuildStopArgsTests {
    @Test("builds sbx stop <name>")
    func buildsStopArgs() throws {
        #expect(try buildStopArgs("my-sandbox") == ["sbx", "stop", "my-sandbox"])
    }

    @Test("throws when name is missing")
    func throwsWhenNameMissing() {
        #expect(throws: SbxKitError.sandboxNameRequired) { try buildStopArgs("") }
    }
}

@Suite("buildRemoveArgs")
struct BuildRemoveArgsTests {
    @Test("builds sbx rm --force <name>")
    func buildsRemoveArgs() throws {
        #expect(try buildRemoveArgs("my-sandbox") == ["sbx", "rm", "--force", "my-sandbox"])
    }

    @Test("throws when name is missing")
    func throwsWhenNameMissing() {
        #expect(throws: SbxKitError.sandboxNameRequired) { try buildRemoveArgs("") }
    }
}

@Suite("buildPolicyAddArgs")
struct BuildPolicyAddArgsTests {
    @Test("joins multiple resources into one comma-separated argv token, allow")
    func joinsResourcesAllow() throws {
        let args = try buildPolicyAddArgs(name: "x", decision: .allow, resources: ["a.com", "*.b.com"])
        #expect(args == ["sbx", "policy", "allow", "network", "--sandbox", "x", "a.com,*.b.com"])
    }

    @Test("builds a deny rule")
    func buildsDenyRule() throws {
        let args = try buildPolicyAddArgs(name: "x", decision: .deny, resources: ["ads.example.com"])
        #expect(args == ["sbx", "policy", "deny", "network", "--sandbox", "x", "ads.example.com"])
    }

    @Test("throws on an empty resource list")
    func throwsOnEmptyResourceList() {
        #expect(throws: SbxKitError.noResources) {
            try buildPolicyAddArgs(name: "x", decision: .allow, resources: [])
        }
    }

    @Test("throws when name is missing")
    func throwsWhenNameMissing() {
        #expect(throws: SbxKitError.sandboxNameRequired) {
            try buildPolicyAddArgs(name: "", decision: .allow, resources: ["a.com"])
        }
    }
}

@Suite("buildPolicyRemoveArgs")
struct BuildPolicyRemoveArgsTests {
    @Test("removes by rule id")
    func removesByRuleId() throws {
        let args = try buildPolicyRemoveArgs(name: "x", ruleId: "abc-123", resource: nil)
        #expect(args == ["sbx", "policy", "rm", "network", "--sandbox", "x", "--id", "abc-123"])
    }

    @Test("removes by resource")
    func removesByResource() throws {
        let args = try buildPolicyRemoveArgs(name: "x", ruleId: nil, resource: "a.com")
        #expect(args == ["sbx", "policy", "rm", "network", "--sandbox", "x", "--resource", "a.com"])
    }

    @Test("throws when neither ruleId nor resource is given")
    func throwsWhenNeitherGiven() {
        #expect(throws: SbxKitError.ruleIdOrResourceRequired) {
            try buildPolicyRemoveArgs(name: "x", ruleId: nil, resource: nil)
        }
    }

    // JS guards on truthiness (`if (!ruleId && !resource) throw`), so an
    // empty string is exactly as absent as null/undefined — a wrong-typed
    // guard using `!= nil` would let an empty ruleId through and build
    // `--id ''`, or fail to fall back to a present `resource`.
    @Test("throws when ruleId is present but empty and resource is absent")
    func throwsWhenRuleIdIsEmptyString() {
        #expect(throws: SbxKitError.ruleIdOrResourceRequired) {
            try buildPolicyRemoveArgs(name: "x", ruleId: "", resource: nil)
        }
    }

    @Test("falls back to resource when ruleId is an empty string")
    func fallsBackToResourceWhenRuleIdIsEmpty() throws {
        let args = try buildPolicyRemoveArgs(name: "x", ruleId: "", resource: "a.com")
        #expect(args == ["sbx", "policy", "rm", "network", "--sandbox", "x", "--resource", "a.com"])
    }

    @Test("throws when name is missing")
    func throwsWhenNameMissing() {
        #expect(throws: SbxKitError.sandboxNameRequired) {
            try buildPolicyRemoveArgs(name: "", ruleId: "abc-123", resource: nil)
        }
    }
}
