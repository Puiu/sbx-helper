// Ports the "preset paths relativize and re-absolutize" case from
// src/electron/test/config.test.mjs, plus new round-trip tests for
// relativePath/resolvePath — Swift has no path.relative()/path.resolve(),
// so this is a genuine reimplementation, purely lexical (no symlink
// resolution, no filesystem access).
import Testing
@testable import SbxKit

@Suite("relativePath / resolvePath round-trip")
struct RelativePathTests {
    @Test("equal paths relativize to an empty string")
    func equalPathsAreEmpty() {
        #expect(relativePath(from: "/root/a", to: "/root/a") == "")
    }

    @Test("a target outside base climbs with ..")
    func targetOutsideBaseClimbs() {
        #expect(relativePath(from: "/root/sub", to: "/root/x") == "../x")
    }

    @Test("base of / relativizes without a leading slash")
    func rootBase() {
        #expect(relativePath(from: "/", to: "/a/b") == "a/b")
    }

    @Test("trailing slashes on either side don't affect the result")
    func trailingSlashesIgnored() {
        #expect(relativePath(from: "/root/", to: "/root/sub/") == "sub")
        #expect(relativePath(from: "/root", to: "/root/sub/") == "sub")
        #expect(relativePath(from: "/root/", to: "/root/sub") == "sub")
    }

    @Test("resolvePath(base, \"\") returns base unchanged")
    func resolveEmptyReturnsBase() {
        #expect(resolvePath("/root/a", "") == "/root/a")
    }

    @Test("resolvePath(base, \".\") returns base unchanged")
    func resolveDotReturnsBase() {
        #expect(resolvePath("/root/a", ".") == "/root/a")
    }

    @Test("an absolute second argument wins and discards base — path.resolve semantics")
    func absoluteArgumentWins() {
        #expect(resolvePath("/root", "/abs/path") == "/abs/path")
    }

    @Test("resolvePath collapses .. segments")
    func resolveCollapsesDotDot() {
        #expect(resolvePath("/root/a/b", "../../c") == "/root/c")
    }

    @Test("relative then resolve round-trips back to the original absolute path")
    func roundTrips() {
        let base = "/Users/alexalbu/repos/nho"
        let target = "/Users/alexalbu/repos/nho/Consent-register/NHO.0476.ConsentRegister.Web"
        let rel = relativePath(from: base, to: target)
        #expect(resolvePath(base, rel) == target)
    }

    @Test("preset paths relativize and re-absolutize")
    func presetPathsRelativizeAndReabsolutize() {
        let root = "/Users/alexalbu/repos/nho"
        let preset = Preset(
            name: "p1", rootPath: root, template: "tpl", sandboxName: nil, clone: false,
            editable: ["\(root)/Consent-register/NHO.0476.ConsentRegister.Web"],
            readOnly: ["\(root)/AccessHubPortal/NHO.AccessHub.Web"]
        )
        let rel = relativizePreset(rootPath: root, preset)
        #expect(rel.editable[0] == "Consent-register/NHO.0476.ConsentRegister.Web")
        #expect(rel.readOnly[0] == "AccessHubPortal/NHO.AccessHub.Web")

        let abs = absolutizePreset(rel)
        #expect(abs.editable[0] == preset.editable[0])
        #expect(abs.readOnly[0] == preset.readOnly[0])
    }
}
