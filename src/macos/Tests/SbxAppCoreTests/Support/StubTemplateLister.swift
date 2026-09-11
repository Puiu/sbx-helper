import Foundation
@testable import SbxAppCore
import SbxServices

final class StubTemplateLister: TemplateListing, @unchecked Sendable {
    private let lock = NSLock()
    private var result: [String]
    private(set) var callCount = 0

    init(result: [String] = []) {
        self.result = result
    }

    func setResult(_ result: [String]) {
        lock.withLock { self.result = result }
    }

    func listTemplates() async -> [String] {
        lock.withLock {
            callCount += 1
            return result
        }
    }
}
