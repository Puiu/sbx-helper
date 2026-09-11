// Ports src/electron/server.mjs's apiReveal path checks (284-296).
import Testing
@testable import SbxKit

struct RevealValidationTests {
    @Test
    func relativePathIsRejected() {
        #expect(throws: SbxKitError.revealPathMustBeAbsolute) {
            try validateRevealPath("rel/path", exists: { _ in true }, isDirectory: { _ in true })
        }
    }

    @Test
    func missingPathReportsFolderNotFound() {
        #expect(throws: SbxKitError.folderNotFound(path: "/root/gone")) {
            try validateRevealPath("/root/gone", exists: { _ in false }, isDirectory: { _ in false })
        }
    }

    @Test
    func filePathReportsNotADirectory() {
        #expect(throws: SbxKitError.notADirectory(path: "/root/file")) {
            try validateRevealPath("/root/file", exists: { _ in true }, isDirectory: { _ in false })
        }
    }

    @Test
    func directoryPathPasses() throws {
        try validateRevealPath("/root/dir", exists: { _ in true }, isDirectory: { _ in true })
    }
}
