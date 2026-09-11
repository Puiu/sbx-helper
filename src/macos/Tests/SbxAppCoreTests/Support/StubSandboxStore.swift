import Foundation
import SbxKit
import SbxServices
@testable import SbxAppCore

/// Scriptable backing for the `SandboxListing`/`SandboxControlling` seams —
/// the Sandboxes-tab analogue of `StubTemplateLister`/`StubLauncher`.
final class StubSandboxStore: SandboxListing, SandboxControlling, @unchecked Sendable {
    private let lock = NSLock()
    var listResult: Result<[Sandbox], SbxCLIFailure> = .success([])
    var stopResult: Result<Void, SbxCLIFailure> = .success(())
    var removeResult: Result<Void, SbxCLIFailure> = .success(())
    var runExistingResult: Result<[String], SbxCLIFailure> = .success([])
    private(set) var calls: [String] = []
    private(set) var runExistingArgs: [(name: String, agentArgs: [String])] = []

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
}
