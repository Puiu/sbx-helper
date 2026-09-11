import Testing
import AppKit
@testable import SbxServices

@Suite("SystemServices")
struct SystemServicesTests {
    @Test("copyToClipboard round-trips through an injected pasteboard")
    func copyRoundTrips() {
        // An isolated pasteboard, not .general — this suite would otherwise
        // clobber whatever the developer running it had actually copied,
        // and the round-trip assertion could be raced by any other app
        // writing to the real clipboard concurrently.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let marker = "sbx-helper-test-\(UUID().uuidString)"
        #expect(SystemServices.copyToClipboard(marker, pasteboard: pasteboard) == true)
        #expect(pasteboard.string(forType: .string) == marker)
    }
}
