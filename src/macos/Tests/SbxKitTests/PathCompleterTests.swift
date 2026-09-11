// Ports src/electron/test/scan.test.mjs (completePath describe block).
import Foundation
import Testing
@testable import SbxKit

private func makeCompletionFixture() -> TempDirectory {
    let dir = TempDirectory()
    dir.makeDirectory("AccessHubPortal")
    dir.makeDirectory("AccessHubOther")
    dir.makeDirectory("Consent-register")
    dir.makeDirectory("node_modules")
    dir.makeDirectory(".hidden")
    dir.makeFile("not-a-dir.txt")
    return dir
}

@Suite("completePath")
struct PathCompleterTests {
    @Test("lists all subfolders for a trailing-slash prefix")
    func listsAllSubfoldersForTrailingSlash() {
        let dir = makeCompletionFixture()
        let completer = PathCompleter(ignoreFolders: [])
        let results = completer.completePath(dir.path + "/")
        #expect(Set(results) == Set([
            dir.joined("AccessHubOther"),
            dir.joined("AccessHubPortal"),
            dir.joined("Consent-register"),
            dir.joined("node_modules"),
        ]))
    }

    @Test("filters by a case-insensitive partial-name prefix")
    func filtersByPartialNamePrefix() {
        let dir = makeCompletionFixture()
        let completer = PathCompleter(ignoreFolders: [])
        let results = completer.completePath(dir.joined("access"))
        #expect(Set(results) == Set([dir.joined("AccessHubOther"), dir.joined("AccessHubPortal")]))
    }

    @Test("excludes ignoreFolders and dot-folders by default")
    func excludesIgnoreFoldersAndDotFolders() {
        let dir = makeCompletionFixture()
        let completer = PathCompleter(ignoreFolders: ["node_modules"])
        let results = completer.completePath(dir.path + "/")
        #expect(!results.contains(dir.joined("node_modules")))
        #expect(!results.contains(dir.joined(".hidden")))
    }

    @Test("shows dot-folders once the partial itself starts with a dot")
    func showsDotFoldersWhenPartialStartsWithDot() {
        let dir = makeCompletionFixture()
        let completer = PathCompleter(ignoreFolders: [])
        // Deliberately not path-joined — that would normalize away the trailing ".".
        let results = completer.completePath("\(dir.path)/.")
        #expect(results.contains(dir.joined(".hidden")))
    }

    @Test("excludes files, only directories")
    func excludesFilesOnlyDirectories() {
        let dir = makeCompletionFixture()
        let completer = PathCompleter(ignoreFolders: [])
        let results = completer.completePath(dir.path + "/")
        #expect(!results.contains(dir.joined("not-a-dir.txt")))
    }

    @Test("returns [] for a non-absolute prefix")
    func returnsEmptyForNonAbsolutePrefix() {
        let completer = PathCompleter(ignoreFolders: [])
        #expect(completer.completePath("relative/path") == [])
    }

    @Test("returns [] for an unreadable or missing base directory")
    func returnsEmptyForMissingBaseDirectory() {
        let completer = PathCompleter(ignoreFolders: [])
        #expect(completer.completePath("/this/does/not/exist/") == [])
    }

    @Test("caps results at 25 subfolders")
    func capsResultsAt25() {
        let dir = TempDirectory()
        for i in 0..<30 { dir.makeDirectory("dir-\(String(format: "%02d", i))") }
        let completer = PathCompleter(ignoreFolders: [])
        #expect(completer.completePath(dir.path + "/").count == 25)
    }
}
