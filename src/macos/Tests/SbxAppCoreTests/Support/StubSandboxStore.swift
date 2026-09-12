import Foundation
import SbxKit
import SbxServices
@testable import SbxAppCore

/// Scriptable backing for the `SandboxListing`/`SandboxControlling` seams —
/// the Sandboxes-tab analogue of `StubTemplateLister`/`StubLauncher`.
final class StubSandboxStore: SandboxListing, SandboxControlling, PolicyControlling, @unchecked Sendable {
    private let lock = NSLock()
    var listResult: Result<[Sandbox], SbxCLIFailure> = .success([])
    var stopResult: Result<Void, SbxCLIFailure> = .success(())
    var removeResult: Result<Void, SbxCLIFailure> = .success(())
    var runExistingResult: Result<[String], SbxCLIFailure> = .success([])
    var listPolicyResult: Result<[PolicyRule], SbxCLIFailure> = .success([])
    var addPolicyResult: Result<[PolicyRule], SbxCLIFailure> = .success([])
    var removePolicyResult: Result<Void, SbxCLIFailure> = .success(())
    private(set) var calls: [String] = []
    private(set) var runExistingArgs: [(name: String, agentArgs: [String])] = []
    private(set) var addPolicyCalls: [(name: String, decision: Decision, resources: [String])] = []
    private(set) var removePolicyCalls: [(name: String, ruleId: String?, resource: String?)] = []
    // Optional per-method gates so a test can hold one policy call in
    // flight while driving the others — the same shape as
    // `StubLauncher`'s gate. Single waiter per method, which is all the
    // concurrency tests need. (One shared flag deadlocks the race tests:
    // the driving call would block on the same gate its own release is
    // sequenced after.)
    private var gatedKeys: Set<String> = []
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]

    func listSandboxes() async -> Result<[Sandbox], SbxCLIFailure> {
        lock.withLock {
            calls.append("list")
            return listResult
        }
    }

    func stop(name: String) async -> Result<Void, SbxCLIFailure> {
        lock.withLock {
            calls.append("stop:\(name)")
            return stopResult
        }
    }

    func remove(name: String) async -> Result<Void, SbxCLIFailure> {
        lock.withLock {
            calls.append("remove:\(name)")
            return removeResult
        }
    }

    func runExisting(name: String, agentArgs: [String]) async -> Result<[String], SbxCLIFailure> {
        lock.withLock {
            calls.append("runExisting:\(name)")
            runExistingArgs.append((name, agentArgs))
            return runExistingResult
        }
    }

    func callCount(_ prefix: String) -> Int {
        lock.withLock { calls.filter { $0 == prefix || $0.hasPrefix(prefix + ":") }.count }
    }

    /// Calls to the gated method block until the matching release.
    func gateList() { lock.withLock { _ = gatedKeys.insert("list") } }
    func releaseList() { release("list") }
    func gateAdd() { lock.withLock { _ = gatedKeys.insert("add") } }
    func releaseAdd() { release("add") }
    func gateRemove() { lock.withLock { _ = gatedKeys.insert("remove") } }
    func releaseRemove() { release("remove") }

    /// Back-compat for the stale-fetch test, which only ever gates the list.
    func gatePolicy() { gateList() }
    func releasePolicy() { releaseList() }

    private func release(_ key: String) {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            gatedKeys.remove(key)
            let c = continuations.removeValue(forKey: key)
            return c
        }
        continuation?.resume()
    }

    private func waitIfGated(_ key: String) async {
        let shouldWait: Bool = lock.withLock { gatedKeys.contains(key) }
        if shouldWait {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.withLock { continuations[key] = c }
            }
        }
    }

    func listNetworkRules(name: String) async -> Result<[PolicyRule], SbxCLIFailure> {
        lock.withLock { calls.append("listPolicy:\(name)") }
        await waitIfGated("list")
        return lock.withLock { listPolicyResult }
    }

    func addPolicy(name: String, decision: Decision, resources: [String]) async -> Result<[PolicyRule], SbxCLIFailure> {
        lock.withLock {
            calls.append("addPolicy:\(name)")
            addPolicyCalls.append((name, decision, resources))
        }
        await waitIfGated("add")
        return lock.withLock { addPolicyResult }
    }

    func removePolicy(name: String, ruleId: String?, resource: String?) async -> Result<Void, SbxCLIFailure> {
        lock.withLock {
            calls.append("removePolicy:\(name)")
            removePolicyCalls.append((name, ruleId, resource))
        }
        await waitIfGated("remove")
        return lock.withLock { removePolicyResult }
    }
}
