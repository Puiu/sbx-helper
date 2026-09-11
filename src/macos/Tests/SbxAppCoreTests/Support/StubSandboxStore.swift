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
    private(set) var addPolicyCalls: [(decision: Decision, resources: [String])] = []
    private(set) var removePolicyCalls: [(ruleId: String?, resource: String?)] = []
    // Optional gate so a test can hold `listNetworkRules` in flight and
    // observe mid-fetch model state before releasing it — the same shape as
    // `StubLauncher`'s gate. Single waiter only, which is all the
    // stale-discard test needs.
    private var policyContinuation: CheckedContinuation<Void, Never>?
    private var policyGated = false

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

    /// Calls to `listNetworkRules` block until `releasePolicy()` is called.
    func gatePolicy() {
        lock.withLock { policyGated = true }
    }

    func releasePolicy() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            // Opening the gate as well as resuming the waiter: later calls
            // proceed without blocking.
            policyGated = false
            let c = self.policyContinuation
            self.policyContinuation = nil
            return c
        }
        continuation?.resume()
    }

    func listNetworkRules(name: String) async -> Result<[PolicyRule], SbxCLIFailure> {
        let shouldWait: Bool = lock.withLock {
            calls.append("listPolicy:\(name)")
            return policyGated
        }
        if shouldWait {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.withLock { policyContinuation = c }
            }
        }
        return lock.withLock { listPolicyResult }
    }

    func addPolicy(name: String, decision: Decision, resources: [String]) async -> Result<[PolicyRule], SbxCLIFailure> {
        lock.withLock {
            calls.append("addPolicy:\(name)")
            addPolicyCalls.append((decision, resources))
            return addPolicyResult
        }
    }

    func removePolicy(name: String, ruleId: String?, resource: String?) async -> Result<Void, SbxCLIFailure> {
        lock.withLock {
            calls.append("removePolicy:\(name)")
            removePolicyCalls.append((ruleId, resource))
            return removePolicyResult
        }
    }
}
