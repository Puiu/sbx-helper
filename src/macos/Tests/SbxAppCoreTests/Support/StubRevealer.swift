import Foundation
import SbxServices

final class StubRevealer: FinderRevealing, @unchecked Sendable {
    private let lock = NSLock()
    private var succeeds: Bool
    private(set) var revealed: [String] = []

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    func reveal(_ path: String) -> Bool {
        lock.withLock {
            revealed.append(path)
            return succeeds
        }
    }
}
