// Ports the pre-launch validation from src/electron/server.mjs's apiRun
// (lines 231-274) — the deleted Node server checked every path was absolute
// and existed before spawning sbx. There is no server layer here, so this
// moves into SbxKit as a pure function with an injected existence check.
import Testing
import Foundation
@testable import SbxKit

@Suite("validateLaunchPaths")
struct LaunchValidationTests {
    @Test("accepts a list of absolute paths that all exist")
    func acceptsAllExisting() throws {
        try validateLaunchPaths(["/root/A", "/root/B"], exists: { _ in true })
    }

    @Test("accepts an empty list")
    func acceptsEmptyList() throws {
        try validateLaunchPaths([], exists: { _ in false })
    }

    @Test("rejects a relative path")
    func rejectsRelativePath() {
        #expect(throws: SbxKitError.notAbsolutePath) {
            try validateLaunchPaths(["relative/path"], exists: { _ in true })
        }
    }

    @Test("rejects a path that does not exist")
    func rejectsMissingPath() {
        #expect(throws: SbxKitError.folderNotFound(path: "/root/gone")) {
            try validateLaunchPaths(["/root/gone"], exists: { _ in false })
        }
    }

    @Test("reports the first failing path when several are bad")
    func reportsFirstFailingPath() {
        // A relative path comes after a missing one — the missing one is
        // positionally first, so it must be the one reported, not the
        // relative one just because it's a "worse" kind of failure.
        #expect(throws: SbxKitError.folderNotFound(path: "/root/gone")) {
            try validateLaunchPaths(
                ["/root/gone", "relative/path"],
                exists: { path in path != "/root/gone" }
            )
        }
    }

    @Test("prefers the not-absolute error for a path that is both relative and missing")
    func prefersNotAbsoluteForRelativeAndMissing() {
        #expect(throws: SbxKitError.notAbsolutePath) {
            try validateLaunchPaths(["relative/gone"], exists: { _ in false })
        }
    }

    @Test("treats a file as present, using the injected exists check")
    func treatsFileAsPresent() throws {
        let dir = TempDirectory()
        let file = dir.makeFile("marker.txt")
        try validateLaunchPaths([file])
    }
}
