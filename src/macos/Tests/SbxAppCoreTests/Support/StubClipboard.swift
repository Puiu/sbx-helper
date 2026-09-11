import Foundation
import SbxServices

final class StubClipboard: ClipboardWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var succeeds: Bool
    private(set) var written: [String] = []

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    func setSucceeds(_ succeeds: Bool) {
        lock.withLock { self.succeeds = succeeds }
    }

    func write(_ text: String) -> Bool {
        lock.withLock {
            written.append(text)
            return succeeds
        }
    }
}
