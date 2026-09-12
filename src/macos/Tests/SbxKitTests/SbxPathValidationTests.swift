// Validates the Settings sheet's `sbx` location field: the configured path
// must be absolute and resolve to something `ToolLocator` would accept
// (exists AND executable — a non-executable file reads as "not found",
// exactly like the locator treats it). Errors are binary-specific, not the
// workspace/folder cases: the sheet surfaces them verbatim next to the
// "sbx not found — set its location in Settings." banner.
import Testing
@testable import SbxKit

struct SbxPathValidationTests {
    @Test
    func relativePathIsRejected() {
        #expect(throws: SbxKitError.sbxPathMustBeAbsolute) {
            try validateSbxPath("rel/sbx", exists: { _ in true }, isExecutable: { _ in true })
        }
    }

    @Test
    func emptyPathIsRejected() {
        #expect(throws: SbxKitError.sbxPathMustBeAbsolute) {
            try validateSbxPath("", exists: { _ in true }, isExecutable: { _ in true })
        }
    }

    @Test
    func missingPathReportsSbxNotFound() {
        #expect(throws: SbxKitError.sbxNotFound(path: "/opt/homebrew/bin/sbx")) {
            try validateSbxPath("/opt/homebrew/bin/sbx", exists: { _ in false }, isExecutable: { _ in false })
        }
    }

    @Test
    func existingButNonExecutablePathReportsSbxNotFound() {
        #expect(throws: SbxKitError.sbxNotFound(path: "/opt/homebrew/bin/sbx")) {
            try validateSbxPath("/opt/homebrew/bin/sbx", exists: { _ in true }, isExecutable: { _ in false })
        }
    }

    @Test
    func existingExecutablePathPasses() throws {
        try validateSbxPath("/opt/homebrew/bin/sbx", exists: { _ in true }, isExecutable: { _ in true })
    }

    @Test
    func messagesNameTheBinaryNotAFolder() {
        #expect(SbxKitError.sbxPathMustBeAbsolute.errorDescription == "sbx path must be an absolute path.")
        #expect(SbxKitError.sbxNotFound(path: "/x/sbx").errorDescription == "sbx not found: /x/sbx")
    }
}
