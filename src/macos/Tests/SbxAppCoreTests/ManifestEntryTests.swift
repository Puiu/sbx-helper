// Ports src/electron/public/app.js's renderManifest (340-356) and
// manifestRow (302-338).
import Testing
import SbxKit
@testable import SbxAppCore

@MainActor
struct ManifestEntryTests {
    @Test
    func entriesListEditablePathsSortedThenReadOnlyPathsSorted() {
        let entries = manifestEntries(
            editable: ["/root/B", "/root/A"],
            readOnly: ["/root/D", "/root/C"],
            primary: nil
        )
        #expect(entries.map(\.path) == ["/root/A", "/root/B", "/root/C", "/root/D"])
        #expect(entries.map(\.kind) == [.editable, .editable, .readOnly, .readOnly])
    }

    @Test
    func theReadOnlySuffixAppearsOnlyInTheDisplayPath() {
        let entries = manifestEntries(editable: [], readOnly: ["/root/A"], primary: nil)
        #expect(entries[0].path == "/root/A")
        #expect(entries[0].displayPath == "/root/A:ro")
    }

    @Test
    func thePrimaryRowIsStarredAndAnnotated() {
        let entries = manifestEntries(editable: ["/root/A"], readOnly: [], primary: "/root/A")
        #expect(entries[0].isPrimary == true)
        #expect(entries[0].star == "★")
        #expect(entries[0].note == "primary")
    }

    @Test
    func aNonPrimaryEditableRowGetsAHollowStarAndNoNote() {
        let entries = manifestEntries(editable: ["/root/A", "/root/B"], readOnly: [], primary: "/root/A")
        let b = entries.first { $0.path == "/root/B" }!
        #expect(b.star == "☆")
        #expect(b.note == "")
    }

    @Test
    func aReadOnlyRowGetsNoStarAndTheReadOnlyNote() {
        let entries = manifestEntries(editable: [], readOnly: ["/root/A"], primary: nil)
        #expect(entries[0].star == "")
        #expect(entries[0].note == "read-only")
    }

    @Test
    func onlyEditableRowsCanBecomePrimary() {
        let entries = manifestEntries(editable: ["/root/A"], readOnly: ["/root/B"], primary: nil)
        #expect(entries.first { $0.path == "/root/A" }!.canBePrimary == true)
        #expect(entries.first { $0.path == "/root/B" }!.canBePrimary == false)
    }

    @Test
    func anExplicitPrimaryThatIsNoLongerEditableFallsBackToTheDefault() {
        let entries = manifestEntries(editable: ["/root/B", "/root/A"], readOnly: [], primary: "/root/Z")
        #expect(entries.first { $0.path == "/root/A" }!.isPrimary == true)
        #expect(entries.first { $0.path == "/root/B" }!.isPrimary == false)
    }

    @Test
    func emptySelectionProducesNoEntries() {
        #expect(manifestEntries(editable: [], readOnly: [], primary: nil).isEmpty)
    }

    @Test
    func thePrimaryIsNotHoistedToTheTopOfTheManifest() {
        // "/root/B" is primary but "/root/A" still sorts first — the
        // manifest order is purely alphabetical within each bucket, unlike
        // orderedWorkspaces for the command.
        let entries = manifestEntries(editable: ["/root/B", "/root/A"], readOnly: [], primary: "/root/B")
        #expect(entries.map(\.path) == ["/root/A", "/root/B"])
        #expect(entries[1].isPrimary == true)
    }

    @Test
    func manifestOrderingMatchesJSOrdinalForCanonicallyEquivalentPaths() {
        let nfc = "/root/caf\u{E9}"
        let nfd = "/root/cafe\u{301}"
        // Swift's `<` treats these as canonically equivalent (neither
        // precedes the other), but UTF-16-ordinal comparison puts the NFD
        // form first (0x65 < 0xE9 at the first differing unit) — the
        // manifest must follow the latter, matching `buildArgs`.
        #expect(!(nfc < nfd) && !(nfd < nfc))
        let jsOrdered = [nfc, nfd].sorted(by: JSOrder.precedes)
        #expect(jsOrdered == [nfd, nfc])
        let entries = manifestEntries(editable: [nfc, nfd], readOnly: [], primary: nil)
        #expect(entries.map(\.path) == jsOrdered)
    }

    @Test
    func builderModelExposesTheManifestForItsCurrentSelection() async {
        let scanner = StubScanner()
        let root = TreeNode(path: "/root", name: "/root", depth: 0, isGitRepo: false, unreadable: false)
        let a = TreeNode(path: "/root/A", name: "A", depth: 1, isGitRepo: false, unreadable: false)
        scanner.setResult(ScannedTree(nodes: [root, a]), for: "/root")
        scanner.release("/root")

        let model = BuilderModel(scanner: scanner, toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in })
        model.scan(root: "/root", maxDepth: 3, ignoreFolders: [])
        await model.quiesce()
        model.setSelection("/root/A", .editable)

        #expect(model.manifest.map(\.path) == ["/root/A"])
        #expect(model.manifest[0].isPrimary == true)
    }
}
