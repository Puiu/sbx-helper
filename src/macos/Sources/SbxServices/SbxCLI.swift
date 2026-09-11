// Ports src/electron/lib/sandboxes.mjs's listSandboxes/listNetworkRules,
// lib/templates.mjs's listTemplates, and server.mjs's requireKnownSandbox +
// the apiSandbox* route handlers' orchestration (argv build -> spawn ->
// parse), using SbxKit's already-ported argv builders and parsers. Never
// throws — every method reports failure through its return type, mirroring
// the JS `{ ok, error }` contract.
import Foundation
import SbxKit

public enum SbxCLIFailure: Error, Sendable, Equatable {
    /// `ToolLocator` couldn't find `sbx` at all.
    case toolNotFound
    /// The underlying `sbx` invocation itself failed (non-zero exit, spawn
    /// error, or unparseable output) — parity with server.mjs's 502.
    case infrastructure(String)
    /// `name` isn't in a fresh `sbx ls --json` — parity with server.mjs's 400
    /// for an unknown sandbox. Never cached: every mutating call re-checks.
    case unknownSandbox(String)
    /// The rule id exists but isn't sandbox-scoped-and-editable — refused
    /// before spawning `policy rm`, never after.
    case ruleNotRemovable(String)
    /// `resources` was empty, exceeded `maxResourcesPerRequest`, or contained
    /// an entry that fails `isValidNetworkResource` — parity with
    /// server.mjs's apiSandboxPolicyAdd 400 ("One or more resources are invalid.").
    case invalidResources
    /// An argv-builder validation error from SbxKit (bad decision, no
    /// resources, too many agent-arg tokens, ...).
    case invalid(SbxKitError)
    /// The mutating command itself exited non-zero.
    case commandFailed(String)
}

/// The one method BuilderModel (Phase 4) needs from SbxCLI, extracted as its
/// own protocol so the model can be tested without a real `sbx` on PATH.
/// Deliberately narrow rather than PLAN.md's broader `SbxInvoking` — nothing
/// in Phase 4 calls anything else, and Phases 6-7 can add their own seams
/// for what they actually need.
///
/// `listTemplates()` collapses every failure (sbx missing, non-zero exit,
/// timeout) into the same empty `[]` as "no templates" — there is no way for
/// a caller to distinguish them. That's intentional for now: the picker
/// always seeds `config.defaultTemplate` first and always offers "Custom…",
/// so it never renders as empty either way. Distinguishing "unavailable"
/// from "empty" is Phase 8's "sbx not found" banner, not this protocol's job.
public protocol TemplateListing: Sendable {
    func listTemplates() async -> [String]
}

extension SbxCLI: TemplateListing {}

/// The slice of `SbxCLI` the Sandboxes tab lists through — extracted so
/// `SandboxesModel` (Phase 6) can be tested without a real `sbx` on PATH,
/// the same reason `TemplateListing` exists for the Builder tab.
public protocol SandboxListing: Sendable {
    func listSandboxes() async -> Result<[Sandbox], SbxCLIFailure>
}

/// The mutating slice of `SbxCLI` the Sandboxes tab drives. Kept separate
/// from `SandboxListing` so a test can script reads and writes
/// independently; `SbxCLI` conforms to both.
public protocol SandboxControlling: Sendable {
    func stop(name: String) async -> Result<Void, SbxCLIFailure>
    func remove(name: String) async -> Result<Void, SbxCLIFailure>
    func runExisting(name: String, agentArgs: [String]) async -> Result<[String], SbxCLIFailure>
}

extension SbxCLI: SandboxListing, SandboxControlling {}

/// The policy slice of `SbxCLI` the Sandboxes tab drives — extracted so
/// `SandboxesModel` (Phase 7) can be tested without a real `sbx` on PATH,
/// the same reason `SandboxListing`/`SandboxControlling` exist. `SbxCLI`
/// conforms to all three.
public protocol PolicyControlling: Sendable {
    func listNetworkRules(name: String) async -> Result<[PolicyRule], SbxCLIFailure>
    func addPolicy(name: String, decision: Decision, resources: [String]) async -> Result<[PolicyRule], SbxCLIFailure>
    func removePolicy(name: String, ruleId: String?, resource: String?) async -> Result<Void, SbxCLIFailure>
}

extension SbxCLI: PolicyControlling {}

public actor SbxCLI {
    private let commandRunner: CommandRunning
    private let toolLocator: ToolLocator
    private let timeout: Duration

    public init(commandRunner: CommandRunning, toolLocator: ToolLocator, timeout: Duration = .seconds(10)) {
        self.commandRunner = commandRunner
        self.toolLocator = toolLocator
        self.timeout = timeout
    }

    /// Spawns `argvWithSbxPrefix` (as built by SbxKit — element 0 is always
    /// the literal "sbx") against the resolved absolute `sbx` path. Drops
    /// that leading element before handing arguments to `CommandRunning`,
    /// which takes `executable:` separately.
    private func invoke(_ argvWithSbxPrefix: [String]) async -> Result<CommandResult, SbxCLIFailure> {
        guard let sbxPath = await toolLocator.resolvedPath() else { return .failure(.toolNotFound) }
        let env = await toolLocator.childEnvironment()
        let result = await commandRunner.run(
            executable: sbxPath, arguments: Array(argvWithSbxPrefix.dropFirst()),
            stdin: nil, environment: env, timeout: timeout, maxOutputBytes: 1_000_000
        )
        return .success(result)
    }

    public func listSandboxes() async -> Result<[Sandbox], SbxCLIFailure> {
        switch await invoke(["sbx", "ls", "--json"]) {
        case .failure(let failure): return .failure(failure)
        case .success(let result):
            guard result.ok else {
                return .failure(.infrastructure(result.stderr.isEmpty ? "sbx ls failed." : result.stderr))
            }
            do { return .success(try parseSandboxLs(result.stdout)) }
            catch { return .failure(.infrastructure("Could not parse sbx ls output: \(error)")) }
        }
    }

    public func listTemplates() async -> [String] {
        guard let sbxPath = await toolLocator.resolvedPath() else { return [] }
        let env = await toolLocator.childEnvironment()
        let result = await commandRunner.run(
            executable: sbxPath, arguments: ["template", "ls"],
            stdin: nil, environment: env, timeout: .seconds(5), maxOutputBytes: 1_000_000
        )
        guard result.ok else { return [] }
        return parseTemplateLs(result.stdout)
    }

    /// Re-lists sandboxes fresh (never cached) and checks membership.
    /// `sbx policy ls <bogus-name> --json` exits 0 and returns the *global*
    /// rules, so every mutating/read call on a name must go through this
    /// first — see src/electron/CLAUDE.md's security-model section.
    private func requireKnownSandbox(_ name: String) async -> Result<Void, SbxCLIFailure> {
        switch await listSandboxes() {
        case .failure(let failure): return .failure(failure)
        case .success(let sandboxes):
            guard sandboxes.contains(where: { $0.name == name }) else { return .failure(.unknownSandbox(name)) }
            return .success(())
        }
    }

    public func listNetworkRules(name: String) async -> Result<[PolicyRule], SbxCLIFailure> {
        if case .failure(let failure) = await requireKnownSandbox(name) { return .failure(failure) }
        return await listNetworkRulesUnchecked(name: name)
    }

    /// `listNetworkRules` without its own `requireKnownSandbox` — for
    /// callers (like `addPolicy`) that already checked the name fresh earlier
    /// in the same operation and would otherwise spawn a second, redundant
    /// `ls --json` just to re-derive something already known.
    private func listNetworkRulesUnchecked(name: String) async -> Result<[PolicyRule], SbxCLIFailure> {
        switch await invoke(["sbx", "policy", "ls", name, "--json"]) {
        case .failure(let failure): return .failure(failure)
        case .success(let result):
            guard result.ok else {
                return .failure(.infrastructure(result.stderr.isEmpty ? "sbx policy ls failed." : result.stderr))
            }
            do { return .success(try parseNetworkRules(stdout: result.stdout, sandboxName: name)) }
            catch { return .failure(.infrastructure("Could not parse sbx policy ls output: \(error)")) }
        }
    }

    public func stop(name: String) async -> Result<Void, SbxCLIFailure> {
        if case .failure(let failure) = await requireKnownSandbox(name) { return .failure(failure) }
        let args: [String]
        do { args = try buildStopArgs(name) } catch { return .failure(.invalid(error)) }
        switch await invoke(args) {
        case .failure(let failure): return .failure(failure)
        case .success(let result): return result.ok ? .success(()) : .failure(.commandFailed(result.stderr))
        }
    }

    public func remove(name: String) async -> Result<Void, SbxCLIFailure> {
        if case .failure(let failure) = await requireKnownSandbox(name) { return .failure(failure) }
        let args: [String]
        do { args = try buildRemoveArgs(name) } catch { return .failure(.invalid(error)) }
        switch await invoke(args) {
        case .failure(let failure): return .failure(failure)
        case .success(let result): return result.ok ? .success(()) : .failure(.commandFailed(result.stderr))
        }
    }

    /// Builds the re-attach argv only — does NOT spawn `sbx run` itself.
    /// That command opens an interactive attached session, so the caller
    /// hands this argv to `TerminalLauncher`, exactly like
    /// server.mjs's apiSandboxRun calling `launcher(args)` rather than `runSbx`.
    public func runExisting(name: String, agentArgs: [String]) async -> Result<[String], SbxCLIFailure> {
        if case .failure(let failure) = await requireKnownSandbox(name) { return .failure(failure) }
        do { return .success(try buildRunExistingArgs(name: name, agentArgs: agentArgs)) }
        catch { return .failure(.invalid(error)) }
    }

    public func addPolicy(name: String, decision: Decision, resources: [String]) async -> Result<[PolicyRule], SbxCLIFailure> {
        if case .failure(let failure) = await requireKnownSandbox(name) { return .failure(failure) }
        // Parity with server.mjs's apiSandboxPolicyAdd: validated here, not
        // inside buildPolicyAddArgs — the JS's own buildPolicyAddArgs never
        // checked resource shape either, only non-emptiness.
        guard !resources.isEmpty, resources.count <= maxResourcesPerRequest, resources.allSatisfy(isValidNetworkResource) else {
            return .failure(.invalidResources)
        }
        let args: [String]
        do { args = try buildPolicyAddArgs(name: name, decision: decision, resources: resources) }
        catch { return .failure(.invalid(error)) }
        switch await invoke(args) {
        case .failure(let failure): return .failure(failure)
        case .success(let result):
            guard result.ok else { return .failure(.commandFailed(result.stderr)) }
            // Unchecked: requireKnownSandbox above already confirmed `name`
            // fresh for this same operation — re-checking it again here would
            // just double the `sbx ls --json` spawns for no added safety.
            return await listNetworkRulesUnchecked(name: name)
        }
    }

    /// Re-validates the target rule against a fresh policy list before
    /// spawning the removal — refuses anything not sandbox-scoped-and-
    /// editable, so a stale or forged rule id (or resource) can't reach a
    /// global rule. Ports server.mjs's apiSandboxPolicyRemove exactly: BOTH
    /// the ruleId and resource lookup paths go through this same fresh
    /// re-list and `removable` check, not just the ruleId one.
    public func removePolicy(name: String, ruleId: String?, resource: String?) async -> Result<Void, SbxCLIFailure> {
        let trimmedRuleId = (ruleId?.isEmpty == false) ? ruleId : nil
        let trimmedResource = (resource?.isEmpty == false) ? resource : nil

        let rules: [PolicyRule]
        switch await listNetworkRules(name: name) {
        case .failure(let failure): return .failure(failure)
        case .success(let r): rules = r
        }

        let target: PolicyRule?
        if let trimmedRuleId {
            target = rules.first(where: { $0.id == trimmedRuleId })
        } else if let trimmedResource {
            target = rules.first(where: { $0.resources.contains(trimmedResource) })
        } else {
            target = nil
        }
        guard let target, target.removable else {
            return .failure(.ruleNotRemovable(trimmedRuleId ?? trimmedResource ?? ""))
        }

        let args: [String]
        do { args = try buildPolicyRemoveArgs(name: name, ruleId: ruleId, resource: resource) }
        catch { return .failure(.invalid(error)) }
        switch await invoke(args) {
        case .failure(let failure): return .failure(failure)
        case .success(let result): return result.ok ? .success(()) : .failure(.commandFailed(result.stderr))
        }
    }
}
