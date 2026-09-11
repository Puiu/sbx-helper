import Testing
import Foundation
@testable import SbxServices
import SbxKit

@Suite("SbxCLI")
struct SbxCLITests {
    func makeCLI(_ harness: ShimHarness) -> SbxCLI {
        var env = harness.environment
        env["SBX_HELPER_SBX_PATH"] = harness.shimPath
        let locator = ToolLocator(
            commandRunner: ProcessRunner(), environment: env, configuredPath: nil,
            fileExists: { $0 == harness.shimPath }
        )
        return SbxCLI(commandRunner: ProcessRunner(), toolLocator: locator)
    }

    @Test("listSandboxes parses the shim's canned ls --json output")
    func listSandboxesParses() async throws {
        let cli = makeCLI(try ShimHarness())
        guard case .success(let sandboxes) = await cli.listSandboxes() else {
            Issue.record("expected success")
            return
        }
        #expect(sandboxes.map(\.name).sorted() == ["test-sandbox-1", "test-sandbox-2"])
        let running = sandboxes.first { $0.name == "test-sandbox-1" }
        #expect(running?.agent == "claude")
        #expect(running?.status == "running")
    }

    @Test("listSandboxes reports an infrastructure failure when sbx ls itself fails")
    func listSandboxesInfraFailure() async throws {
        let harness = try ShimHarness()
        var env = harness.environment
        env["SBX_SHIM_FAIL_LS"] = "1"
        env["SBX_HELPER_SBX_PATH"] = harness.shimPath
        let locator = ToolLocator(commandRunner: ProcessRunner(), environment: env, configuredPath: nil, fileExists: { $0 == harness.shimPath })
        let cli = SbxCLI(commandRunner: ProcessRunner(), toolLocator: locator)
        guard case .failure(.infrastructure) = await cli.listSandboxes() else {
            Issue.record("expected .infrastructure")
            return
        }
    }

    @Test("listNetworkRules classifies sandbox-scoped rules as removable, global rules as not")
    func listNetworkRulesClassifies() async throws {
        let cli = makeCLI(try ShimHarness())
        guard case .success(let rules) = await cli.listNetworkRules(name: "test-sandbox-1") else {
            Issue.record("expected success")
            return
        }
        #expect(rules.first { $0.id == "removable-rule-id" }?.removable == true)
        #expect(rules.first { $0.id == "default-ai-services" }?.removable == false)
    }

    @Test("listNetworkRules rejects an unknown sandbox without spawning policy ls for it")
    func listNetworkRulesRejectsUnknown() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .failure(.unknownSandbox) = await cli.listNetworkRules(name: "no-such-sandbox") else {
            Issue.record("expected .unknownSandbox")
            return
        }
        let policyLsForBogus = harness.loggedArgv().contains {
            $0.first == "policy" && $0.dropFirst().first == "ls" && $0.dropFirst(2).first == "no-such-sandbox"
        }
        #expect(!policyLsForBogus)
    }

    @Test("stop spawns exactly sbx stop <name>")
    func stopSpawnsExactArgv() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .success = await cli.stop(name: "test-sandbox-1") else {
            Issue.record("expected success")
            return
        }
        #expect(harness.loggedArgv().filter { $0.first == "stop" } == [["stop", "test-sandbox-1"]])
    }

    @Test("stop rejects an unknown sandbox name without spawning stop")
    func stopRejectsUnknown() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .failure(.unknownSandbox) = await cli.stop(name: "no-such-sandbox") else {
            Issue.record("expected .unknownSandbox")
            return
        }
        #expect(harness.loggedArgv().filter { $0.first == "stop" }.isEmpty)
    }

    @Test("remove spawns exactly sbx rm --force <name>")
    func removeSpawnsExactArgv() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .success = await cli.remove(name: "test-sandbox-2") else {
            Issue.record("expected success")
            return
        }
        #expect(harness.loggedArgv().filter { $0.first == "rm" } == [["rm", "--force", "test-sandbox-2"]])
    }

    @Test("runExisting builds the re-attach argv (leading sbx token included) without spawning anything")
    func runExistingBuildsArgv() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .success(let argv) = await cli.runExisting(name: "test-sandbox-1", agentArgs: ["--model", "opusplan"]) else {
            Issue.record("expected success")
            return
        }
        #expect(argv == ["sbx", "run", "--name", "test-sandbox-1", "--", "--model", "opusplan"])
        #expect(harness.loggedArgv().filter { $0.first == "run" }.isEmpty) // never itself spawns `sbx run`
    }

    @Test("runExisting omits the -- separator when no args are given")
    func runExistingOmitsSeparator() async throws {
        let cli = makeCLI(try ShimHarness())
        guard case .success(let argv) = await cli.runExisting(name: "test-sandbox-2", agentArgs: []) else {
            Issue.record("expected success")
            return
        }
        #expect(argv == ["sbx", "run", "--name", "test-sandbox-2"])
    }

    @Test("addPolicy spawns the allow rule with --sandbox always present, then re-lists rules")
    func addPolicySpawnsAndRelists() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .success(let rules) = await cli.addPolicy(name: "test-sandbox-1", decision: .allow, resources: ["example.com"]) else {
            Issue.record("expected success")
            return
        }
        #expect(rules.count == 2)
        let mutating = harness.loggedArgv().filter { $0.first == "policy" && $0.dropFirst().first != "ls" }
        #expect(mutating == [["policy", "allow", "network", "--sandbox", "test-sandbox-1", "example.com"]])
    }

    @Test("removePolicy by rule id spawns exactly the rm invocation")
    func removePolicyByIdSpawns() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .success = await cli.removePolicy(name: "test-sandbox-1", ruleId: "removable-rule-id", resource: nil) else {
            Issue.record("expected success")
            return
        }
        let mutating = harness.loggedArgv().filter { $0.first == "policy" && $0.dropFirst().first == "rm" }
        #expect(mutating == [["policy", "rm", "network", "--sandbox", "test-sandbox-1", "--id", "removable-rule-id"]])
    }

    @Test("removePolicy refuses a non-removable (global) rule id without spawning a removal")
    func removePolicyRefusesGlobalRule() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .failure(.ruleNotRemovable) = await cli.removePolicy(name: "test-sandbox-1", ruleId: "default-ai-services", resource: nil) else {
            Issue.record("expected .ruleNotRemovable")
            return
        }
        #expect(harness.loggedArgv().filter { $0.first == "policy" && $0.dropFirst().first == "rm" }.isEmpty)
    }

    @Test("listTemplates parses the shim's canned template ls table")
    func listTemplatesParses() async throws {
        let cli = makeCLI(try ShimHarness())
        #expect(await cli.listTemplates() == ["claude-sbx-dotnet10:v2", "claude-sbx-python:v1"])
    }

    @Test("listTemplates returns [] without throwing when sbx can't be located")
    func listTemplatesEmptyWhenToolMissing() async throws {
        // A FakeCommandRunner that always fails, not the real ProcessRunner —
        // with fixedProbePaths empty and fileExists always false, resolve()
        // falls through to the shell probe (`/bin/zsh -lc "command -v sbx"`);
        // a real ProcessRunner there would spawn the REAL probe against this
        // machine's actual shell environment, which can find a real `sbx` and
        // make this test pass for an unrelated reason (verified: it does,
        // here). The fake makes the "tool not found" path deterministic.
        struct AlwaysFailRunner: CommandRunning {
            func run(executable: String, arguments: [String], stdin: Data?, environment: [String: String], timeout: Duration, maxOutputBytes: Int) async -> CommandResult {
                CommandResult(ok: false, exitCode: 1, stdout: "", stderr: "not found")
            }
        }
        let locator = ToolLocator(
            commandRunner: AlwaysFailRunner(), environment: [:], configuredPath: nil,
            fixedProbePaths: [], fileExists: { _ in false }
        )
        let cli = SbxCLI(commandRunner: AlwaysFailRunner(), toolLocator: locator)
        #expect(await cli.listTemplates() == [])
    }

    @Test("addPolicy rejects an invalid resource without spawning anything")
    func addPolicyRejectsInvalidResource() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .failure(.invalidResources) = await cli.addPolicy(name: "test-sandbox-1", decision: .allow, resources: ["a b"]) else {
            Issue.record("expected .invalidResources")
            return
        }
        #expect(harness.loggedArgv().filter { $0.first == "policy" }.isEmpty)
    }

    @Test("addPolicy rejects an empty resources list without spawning anything")
    func addPolicyRejectsEmptyResources() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .failure(.invalidResources) = await cli.addPolicy(name: "test-sandbox-1", decision: .allow, resources: []) else {
            Issue.record("expected .invalidResources")
            return
        }
        #expect(harness.loggedArgv().filter { $0.first == "policy" }.isEmpty)
    }

    @Test("addPolicy issues exactly one ls --json, not a redundant second one for the re-list")
    func addPolicyDoesNotDuplicateKnownSandboxCheck() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .success = await cli.addPolicy(name: "test-sandbox-1", decision: .allow, resources: ["example.com"]) else {
            Issue.record("expected success")
            return
        }
        let lsJsonCalls = harness.loggedArgv().filter { $0 == ["ls", "--json"] }
        #expect(lsJsonCalls.count == 1)
    }

    @Test("removePolicy by resource spawns exactly the rm invocation for a removable rule")
    func removePolicyByResourceSpawns() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .success = await cli.removePolicy(name: "test-sandbox-1", ruleId: nil, resource: "ads.example.com") else {
            Issue.record("expected success")
            return
        }
        let mutating = harness.loggedArgv().filter { $0.first == "policy" && $0.dropFirst().first == "rm" }
        #expect(mutating == [["policy", "rm", "network", "--sandbox", "test-sandbox-1", "--resource", "ads.example.com"]])
    }

    @Test("removePolicy by resource refuses a non-removable (global) resource without spawning a removal")
    func removePolicyByResourceRefusesGlobalRule() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .failure(.ruleNotRemovable) = await cli.removePolicy(name: "test-sandbox-1", ruleId: nil, resource: "api.anthropic.com:443") else {
            Issue.record("expected .ruleNotRemovable")
            return
        }
        #expect(harness.loggedArgv().filter { $0.first == "policy" && $0.dropFirst().first == "rm" }.isEmpty)
    }
}
