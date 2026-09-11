// A `TreeScanning` stub whose per-root calls are released by the test in a
// chosen order. Deliberately ignores Task cancellation — it's the vehicle
// ScanCoordinationTests uses to prove a stale scan can't win even when the
// underlying scanner never cooperatively returns early on its own; see
// BuilderModel.scan's doc comment for what that guard actually relies on.
import Foundation
@testable import SbxAppCore

final class StubScanner: TreeScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: ScannedTree] = [:]
    // A queue per root, not a single slot — BuilderModel can legitimately
    // call scan() twice for the same root before either completes (e.g. a
    // rescan of the current root), and each call must get its own
    // continuation rather than the second overwriting the first's.
    private var pendingByRoot: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var released: Set<String> = []
    private(set) var callOrder: [String] = []

    func setResult(_ tree: ScannedTree, for root: String) {
        lock.withLock { results[root] = tree }
    }

    /// Marks `root` as free to complete — resumes every call currently
    /// queued for it, and any future call for it completes immediately.
    /// Safe to call before or after the matching `scan(root:...)` call(s).
    func release(_ root: String) {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            released.insert(root)
            return pendingByRoot.removeValue(forKey: root) ?? []
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    func scan(root: String, maxDepth: Int, ignoreFolders: Set<String>) async -> ScannedTree {
        let alreadyReleased: Bool = lock.withLock {
            callOrder.append(root)
            return released.contains(root)
        }

        if !alreadyReleased {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let shouldResumeNow: Bool = lock.withLock {
                    if released.contains(root) {
                        return true
                    }
                    pendingByRoot[root, default: []].append(continuation)
                    return false
                }
                if shouldResumeNow {
                    continuation.resume()
                }
            }
        }

        return lock.withLock { results[root] ?? .empty }
    }
}
