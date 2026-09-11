import Foundation
import SbxServices

final class StubLauncher: TerminalLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var result: LaunchResult
    private(set) var calls: [[String]] = []
    // Optional gate so a test can hold `launch` in flight and observe
    // mid-launch model state before releasing it.
    private var continuation: CheckedContinuation<Void, Never>?
    private var gated = false

    init(result: LaunchResult = LaunchResult(ok: true, method: "iterm-applescript", error: nil)) {
        self.result = result
    }

    func setResult(_ result: LaunchResult) {
        lock.withLock { self.result = result }
    }

    /// Calls to `launch` block until `release()` is called.
    func gate() {
        lock.withLock { gated = true }
    }

    func release() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            let c = self.continuation
            self.continuation = nil
            return c
        }
        continuation?.resume()
    }

    func launch(args: [String]) async -> LaunchResult {
        let shouldWait: Bool = lock.withLock {
            calls.append(args)
            return gated
        }
        if shouldWait {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.withLock { continuation = c }
            }
        }
        return lock.withLock { result }
    }
}
