// Ports src/electron/public/app.js's setSelection (121-136) and its
// render-time covering-path computation (216-230) — the tri-state
// editable/read-only/off selection, the nested-mount lockout, and primary
// resolution.
import Testing
import SbxKit
@testable import SbxAppCore

@MainActor
struct BuilderSelectionTests {
    private static let root = TreeNode(path: "/root", name: "/root", depth: 0, isGitRepo: false, unreadable: false)
    private static let a = TreeNode(path: "/root/A", name: "A", depth: 1, isGitRepo: false, unreadable: false)
    private static let aB = TreeNode(path: "/root/A/B", name: "B", depth: 2, isGitRepo: false, unreadable: false)
    private static let c = TreeNode(path: "/root/C", name: "C", depth: 1, isGitRepo: false, unreadable: false)

    private func scannedModel() async -> (BuilderModel, ToastCenter) {
        let scanner = StubScanner()
        let tree = ScannedTree(nodes: [Self.root, Self.a, Self.aB, Self.c])
        scanner.setResult(tree, for: "/root")
        scanner.release("/root")

        let toasts = ToastCenter()
        let model = BuilderModel(scanner: scanner, toasts: toasts, templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in })
        model.scan(root: "/root", maxDepth: 3, ignoreFolders: [])
        await model.quiesce()
        return (model, toasts)
    }

    @Test
    func selectingAFolderAsEditableRecordsIt() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/A", .editable)
        #expect(model.editablePaths == ["/root/A"])
    }

    @Test
    func selectingAFolderAsReadOnlyRecordsIt() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/A", .readOnly)
        #expect(model.readOnlyPaths == ["/root/A"])
    }

    @Test
    func settingNilRemovesTheSelection() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/A", .editable)
        model.setSelection("/root/A", nil)
        #expect(model.editablePaths.isEmpty)
        #expect(model.readOnlyPaths.isEmpty)
    }

    @Test
    func changingAnEditableFolderToReadOnlyInPlaceIsAllowed() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/A", .editable)
        model.setSelection("/root/A", .readOnly)
        #expect(model.readOnlyPaths == ["/root/A"])
        #expect(model.editablePaths.isEmpty)
    }

    @Test
    func selectingADescendantOfASelectedFolderIsRejected() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/A", .editable)
        model.setSelection("/root/A/B", .editable)
        #expect(model.editablePaths == ["/root/A"])
    }

    @Test
    func selectingAnAncestorOfASelectedFolderIsRejected() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/A/B", .editable)
        model.setSelection("/root/A", .editable)
        #expect(model.editablePaths == ["/root/A/B"])
    }

    @Test
    func aRejectedSelectionRaisesTheOverlapToast() async {
        let (model, toasts) = await scannedModel()
        model.setSelection("/root/A", .editable)
        model.setSelection("/root/A/B", .editable)
        #expect(toasts.current?.message == "Can't select that — it overlaps an existing selection.")
        #expect(toasts.current?.isError == true)
    }

    @Test
    func aRejectedSelectionLeavesTheSelectionUnchanged() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/A", .editable)
        model.setSelection("/root/A/B", .readOnly)
        #expect(model.editablePaths == ["/root/A"])
        #expect(model.readOnlyPaths.isEmpty)
    }

    @Test
    func deselectingIsAllowedEvenWhenCovered() async {
        let (model, toasts) = await scannedModel()
        model.setSelection("/root/A", .editable)
        // /root/A/B is covered, but clearing it (kind == nil) must skip the
        // covering check entirely per app.js's setSelection. `/root/A/B` was
        // never selected, so `editablePaths` alone can't tell "the check was
        // skipped" apart from "the check ran, was rejected, and left state
        // unchanged" — both leave editablePaths at ["/root/A"]. Asserting no
        // toast fired is what actually pins "skipped", not "rejected".
        model.setSelection("/root/A/B", nil)
        #expect(model.editablePaths == ["/root/A"])
        #expect(toasts.current == nil)
    }

    @Test
    func deselectingThePrimaryClearsPrimary() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/A", .editable)
        model.setPrimary("/root/A")
        model.setSelection("/root/A", nil)
        #expect(model.primary == nil)
    }

    @Test
    func deselectingANonPrimaryLeavesPrimaryAlone() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/A", .editable)
        model.setSelection("/root/C", .editable)
        model.setPrimary("/root/A")
        model.setSelection("/root/C", nil)
        #expect(model.primary == "/root/A")
    }

    @Test
    func convertingThePrimaryToReadOnlyLeavesPrimaryStaleButInert() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/A", .editable)
        model.setSelection("/root/C", .editable)
        model.setPrimary("/root/A")
        model.setSelection("/root/A", .readOnly)
        // Stale: still names the folder that's no longer editable.
        #expect(model.primary == "/root/A")
        // Inert: resolvedPrimary only considers editable paths, so it has
        // already moved on to the remaining editable folder.
        #expect(model.resolvedPrimary == "/root/C")
    }

    @Test
    func resolvedPrimaryDefaultsToTheFirstEditablePathInOrder() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/C", .editable)
        model.setSelection("/root/A", .editable)
        #expect(model.resolvedPrimary == "/root/A")
    }

    @Test
    func resolvedPrimaryHonoursAnExplicitPrimaryThatIsStillEditable() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/C", .editable)
        model.setSelection("/root/A", .editable)
        model.setPrimary("/root/C")
        #expect(model.resolvedPrimary == "/root/C")
    }

    @Test
    func toggleSelectionClearsAMatchingKind() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/A", .editable)
        model.toggleSelection("/root/A", .editable)
        #expect(model.editablePaths.isEmpty)
    }

    @Test
    func toggleSelectionConvertsABetweenKinds() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/A", .editable)
        model.toggleSelection("/root/A", .readOnly)
        #expect(model.readOnlyPaths == ["/root/A"])
        #expect(model.editablePaths.isEmpty)
    }

    @Test
    func coveringPathIsNilForAnAlreadySelectedPath() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root/A", .editable)
        model.setSelection("/root/A/B", nil) // never selected — still covered
        #expect(model.coveringPath(for: "/root/A") == nil)
    }

    @Test
    func coveredByLabelNamesRootForTheRootNodeAndTheLeafNameOtherwise() async {
        let (model, _) = await scannedModel()
        model.setSelection("/root", .editable)
        #expect(model.coveredByLabel(for: "/root/A") == "covered by root")

        model.setSelection("/root", nil)
        model.setSelection("/root/A", .editable)
        #expect(model.coveredByLabel(for: "/root/A/B") == "covered by A")
    }

    @Test
    func aRootChangeClearsSelectionPrimaryAndFilter() async {
        let scanner = StubScanner()
        scanner.setResult(ScannedTree(nodes: [Self.root, Self.a]), for: "/root")
        scanner.setResult(ScannedTree(nodes: [Self.root]), for: "/other")
        scanner.release("/root")
        scanner.release("/other")

        let model = BuilderModel(scanner: scanner, toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in })
        model.scan(root: "/root", maxDepth: 3, ignoreFolders: [])
        await model.quiesce()
        model.setSelection("/root/A", .editable)
        model.setPrimary("/root/A")
        model.filterText = "A"

        model.scan(root: "/other", maxDepth: 3, ignoreFolders: [])
        await model.quiesce()

        #expect(model.editablePaths.isEmpty)
        #expect(model.primary == nil)
        #expect(model.filterText.isEmpty)
    }

    @Test
    func aSameRootRescanPreservesSelectionAndFilter() async {
        let scanner = StubScanner()
        scanner.setResult(ScannedTree(nodes: [Self.root, Self.a]), for: "/root")
        scanner.release("/root")
        let model = BuilderModel(scanner: scanner, toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in })
        model.scan(root: "/root", maxDepth: 3, ignoreFolders: [])
        await model.quiesce()
        model.setSelection("/root/A", .editable)
        model.filterText = "A"

        model.scan(root: "/root", maxDepth: 3, ignoreFolders: [])
        await model.quiesce()

        #expect(model.editablePaths == ["/root/A"])
        #expect(model.filterText == "A")
    }
}
