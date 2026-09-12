import Testing
import SbxKit
@testable import SbxAppCore

@MainActor
struct ScanCoordinationTests {
    private static func node(_ path: String) -> TreeNode {
        TreeNode(path: path, name: path, depth: 0, isGitRepo: false, unreadable: false)
    }

    private static func child(_ path: String, depth: Int) -> TreeNode {
        TreeNode(path: path, name: path, depth: depth, isGitRepo: false, unreadable: false)
    }

    @Test
    func aStaleScanReleasedAfterTheNewerOneStillLosesTheRace() async {
        let scanner = StubScanner()
        scanner.setResult(ScannedTree(nodes: [Self.node("/A")]), for: "/A")
        scanner.setResult(ScannedTree(nodes: [Self.node("/B")]), for: "/B")

        // Long spinner delay so this test only exercises generation
        // discarding, not the spinner race (that's the next two tests).
        let model = BuilderModel(scanner: scanner, toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in }, spinnerDelay: .seconds(10))
        model.scan(root: "/A", maxDepth: 3, ignoreFolders: [])
        model.scan(root: "/B", maxDepth: 3, ignoreFolders: [])

        // Release the older scan ("/A") last — it must still lose.
        scanner.release("/B")
        await Task.yield()
        scanner.release("/A")
        await model.quiesce()

        #expect(model.rootPath == "/B")
        #expect(model.tree.nodes.map(\.path) == ["/B"])
    }

    @Test
    func aScanFasterThanTheSpinnerDelayNeverShowsScanning() async {
        let scanner = StubScanner()
        scanner.setResult(ScannedTree(nodes: [Self.node("/root")]), for: "/root")

        let model = BuilderModel(scanner: scanner, toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in }, spinnerDelay: .milliseconds(200))
        model.scan(root: "/root", maxDepth: 3, ignoreFolders: [])

        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.isScanning == false) // spinner delay hasn't elapsed yet

        scanner.release("/root")
        await model.quiesce()

        #expect(model.isScanning == false)
    }

    @Test
    func aScanSlowerThanTheSpinnerDelayShowsScanningThenClearsIt() async {
        let scanner = StubScanner()
        scanner.setResult(ScannedTree(nodes: [Self.node("/root")]), for: "/root")

        let model = BuilderModel(scanner: scanner, toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in }, spinnerDelay: .milliseconds(20))
        model.scan(root: "/root", maxDepth: 3, ignoreFolders: [])

        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.isScanning == true)

        scanner.release("/root")
        await model.quiesce()

        #expect(model.isScanning == false)
    }

    @Test
    func quiesceSettlesWithNoScansInFlight() async {
        let model = BuilderModel(scanner: StubScanner(), toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in })
        await model.quiesce()
        #expect(model.isScanning == false)
    }

    @Test
    func scanningANewRootClearsExpandedAndResetsCursorToTheNewRoot() async {
        let scanner = StubScanner()
        scanner.setResult(ScannedTree(nodes: [Self.node("/A"), Self.child("/A/x", depth: 1)]), for: "/A")
        scanner.setResult(ScannedTree(nodes: [Self.node("/B")]), for: "/B")
        scanner.release("/A")
        scanner.release("/B")

        let model = BuilderModel(scanner: scanner, toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in })
        model.scan(root: "/A", maxDepth: 3, ignoreFolders: [])
        await model.quiesce()
        model.toggleExpanded("/A/x")
        model.cursor = "/A/x"

        model.scan(root: "/B", maxDepth: 3, ignoreFolders: [])
        await model.quiesce()

        #expect(model.expanded.isEmpty)
        #expect(model.cursor == "/B")
    }

    @Test
    func rescanningTheSameRootPreservesExpandedAndCursorWhenStillValid() async {
        let scanner = StubScanner()
        let firstScan = ScannedTree(nodes: [Self.node("/root"), Self.child("/root/x", depth: 1)])
        scanner.setResult(firstScan, for: "/root")
        scanner.release("/root")

        let model = BuilderModel(scanner: scanner, toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in })
        model.scan(root: "/root", maxDepth: 3, ignoreFolders: [])
        await model.quiesce()
        model.toggleExpanded("/root/x")
        model.cursor = "/root/x"

        // Same content on rescan — "/root/x" still exists afterward.
        model.scan(root: "/root", maxDepth: 3, ignoreFolders: [])
        await model.quiesce()

        #expect(model.expanded.contains("/root/x"))
        #expect(model.cursor == "/root/x")
    }

    @Test
    func rescanningTheSameRootFallsBackTheCursorIfItNoLongerExists() async {
        let scanner = StubScanner()
        let model = BuilderModel(scanner: scanner, toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in })

        scanner.setResult(
            ScannedTree(nodes: [Self.node("/root"), Self.child("/root/x", depth: 1)]), for: "/root"
        )
        scanner.release("/root")
        model.scan(root: "/root", maxDepth: 3, ignoreFolders: [])
        await model.quiesce()
        model.cursor = "/root/x"

        // "/root/x" was deleted since the first scan — rescan comes back without it.
        scanner.setResult(ScannedTree(nodes: [Self.node("/root")]), for: "/root")
        model.scan(root: "/root", maxDepth: 3, ignoreFolders: [])
        await model.quiesce()

        #expect(model.cursor == "/root")
    }

    @Test
    func inFlightTaskBookkeepingDrainsAfterEachScanWithoutQuiesce() async {
        // Regression for unbounded growth: production never calls quiesce(),
        // so each scan's tasks must remove themselves on completion rather
        // than accumulate for the model's lifetime (e.g. every ⌘R).
        let scanner = StubScanner()
        let model = BuilderModel(scanner: scanner, toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in }, spinnerDelay: .milliseconds(1))

        for i in 0..<5 {
            let root = "/root\(i)"
            scanner.setResult(ScannedTree(nodes: [Self.node(root)]), for: root)
            scanner.release(root)
            model.scan(root: root, maxDepth: 3, ignoreFolders: [])
            // Give both the scan's and the (short-delayed) spinner's `defer`
            // cleanup a chance to run, without relying on the test-only
            // quiesce() — that's the point of this test.
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.inFlightTaskCountForTesting == 0)
    }

    @Test
    func hasCompletedScanStartsFalse() {
        let scanner = StubScanner()
        let model = BuilderModel(scanner: scanner, toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in }, spinnerDelay: .seconds(10))

        #expect(model.hasCompletedScan == false)
    }

    @Test
    func hasCompletedScanBecomesTrueOnceAScanLands() async {
        let scanner = StubScanner()
        scanner.setResult(ScannedTree(nodes: [Self.node("/root")]), for: "/root")
        let model = BuilderModel(scanner: scanner, toasts: ToastCenter(), templateLister: StubTemplateLister(), launcher: StubLauncher(), clipboard: StubClipboard(), persistTemplate: { _ in }, spinnerDelay: .seconds(10))
        model.scan(root: "/root", maxDepth: 3, ignoreFolders: [])

        #expect(model.hasCompletedScan == false)

        scanner.release("/root")
        await model.quiesce()

        #expect(model.hasCompletedScan == true)
    }
}
