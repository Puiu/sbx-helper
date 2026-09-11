// Ports src/electron/public/app.js's root dialog (517-634), save-preset
// dialog (636-676), presets dialog (678-783) and revealInFinder (191-197),
// plus server.mjs's apiScan/apiPresets persistence behind them.
import Testing
import Foundation
import SbxKit
import SbxServices
@testable import SbxAppCore

@MainActor
struct BuilderDialogsTests {
    private static func node(_ path: String, depth: Int) -> TreeNode {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return TreeNode(path: path, name: name, depth: depth, isGitRepo: false, unreadable: false)
    }

    private func harness(
        scanner: StubScanner = StubScanner(),
        toasts: ToastCenter = ToastCenter(),
        revealer: StubRevealer = StubRevealer(),
        configDir: TempDirectory = TempDirectory(),
        pathIsDirectory: (@Sendable (String) -> Bool)? = nil
    ) -> (BuilderModel, AppModel, ToastCenter, StubScanner, StubRevealer) {
        let store = ConfigStore(path: (configDir.path as NSString).appendingPathComponent("sbx-helper.json"))
        let app = AppModel(configStore: store)
        let builder = BuilderModel(
            scanner: scanner,
            toasts: toasts,
            templateLister: StubTemplateLister(),
            launcher: StubLauncher(),
            clipboard: StubClipboard(),
            persistTemplate: { [app] template in await app.update { $0.defaultTemplate = template } },
            mutateConfig: { [app] transform in await app.update(transform) },
            revealer: revealer,
            pathIsDirectory: pathIsDirectory ?? {
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
            },
            spinnerDelay: .milliseconds(10)
        )
        return (builder, app, toasts, scanner, revealer)
    }

    private func scanRoot(
        _ model: BuilderModel, _ scanner: StubScanner, root: String, children: [String] = []
    ) async {
        var nodes = [Self.node(root, depth: 0)]
        nodes += children.map { Self.node($0, depth: 1) }
        scanner.setResult(ScannedTree(nodes: nodes), for: root)
        scanner.release(root)
        model.scan(root: root, maxDepth: 3, ignoreFolders: [])
        await model.quiesce()
    }

    // -- root picker --

    @Test
    func changeRootToNewDirectoryRescansAndUpdatesConfigAndRecents() async {
        let fs = TempDirectory()
        let oldRoot = fs.makeDirectory("old")
        let newRoot = fs.makeDirectory("new")
        let configDir = TempDirectory()
        let (model, app, toasts, scanner, _) = harness(configDir: configDir)
        await app.load()
        await scanRoot(model, scanner, root: oldRoot)
        model.setSelection(oldRoot + "/A", .editable)
        scanner.setResult(ScannedTree(nodes: [Self.node(newRoot, depth: 0)]), for: newRoot)

        let error = await model.changeRoot(to: newRoot, maxDepth: 3, ignoreFolders: [])
        scanner.release(newRoot)
        await model.quiesce()

        #expect(error == nil)
        #expect(toasts.current == nil)
        #expect(model.rootPath == newRoot)
        #expect(model.selection.isEmpty)
        #expect(app.config.rootPath == newRoot)
        #expect(app.config.recentRoots.first == newRoot)
    }

    @Test
    func changeRootToMissingDirectoryReturnsErrorAndKeepsState() async {
        let fs = TempDirectory()
        let oldRoot = fs.makeDirectory("old")
        let (model, app, toasts, scanner, _) = harness()
        await app.load()
        await scanRoot(model, scanner, root: oldRoot)
        let callsBefore = scanner.callOrder.count

        let error = await model.changeRoot(to: oldRoot + "-gone", maxDepth: 3, ignoreFolders: [])

        #expect(error == "Not found: \(oldRoot)-gone")
        #expect(model.rootPath == oldRoot)
        #expect(scanner.callOrder.count == callsBefore)
        #expect(app.config.rootPath != oldRoot + "-gone")
        #expect(toasts.current == nil)
    }

    @Test
    func changeRootToAFileReturnsNotADirectory() async {
        let fs = TempDirectory()
        let oldRoot = fs.makeDirectory("old")
        let file = fs.makeFile("file.txt")
        let (model, _, _, scanner, _) = harness()
        await scanRoot(model, scanner, root: oldRoot)

        let error = await model.changeRoot(to: file, maxDepth: 3, ignoreFolders: [])

        #expect(error == "Not a directory: \(file)")
        #expect(model.rootPath == oldRoot)
    }

    @Test
    func changeRootWithABlankFieldReturnsRequired() async {
        let (model, _, _, _, _) = harness()

        let error = await model.changeRoot(to: "   ", maxDepth: 3, ignoreFolders: [])

        #expect(error == "rootPath is required.")
    }

    // -- save preset --

    @Test
    func savePresetPersistsARelativizedPresetAndToastsSaved() async {
        let fs = TempDirectory()
        let root = fs.makeDirectory("repos")
        let (model, app, toasts, scanner, _) = harness()
        await app.load()
        await scanRoot(model, scanner, root: root)
        model.template = "tpl"
        model.sandboxName = "sbx1"
        model.clone = true
        model.setSelection(root + "/A", .editable)
        model.setSelection(root + "/B", .readOnly)

        let error = await model.savePreset(name: "  p  ", existingPresets: [])

        #expect(error == nil)
        #expect(app.config.presets.count == 1)
        let preset = app.config.presets[0]
        #expect(preset.name == "p")
        #expect(preset.rootPath == root)
        #expect(preset.template == "tpl")
        #expect(preset.sandboxName == "sbx1")
        #expect(preset.clone == true)
        #expect(preset.editable == ["A"])
        #expect(preset.readOnly == ["B"])
        #expect(toasts.current?.message == "Preset \"p\" saved.")
        #expect(toasts.current?.isError == false)
    }

    @Test
    func savePresetWithABlankNameReturnsAnInlineError() async {
        let (model, app, toasts, scanner, _) = harness()
        await scanRoot(model, scanner, root: "/R")
        model.template = "tpl"
        model.setSelection("/R/A", .editable)

        let error = await model.savePreset(name: "  ", existingPresets: [])

        #expect(error == "Preset name is required.")
        #expect(app.config.presets.isEmpty)
        #expect(toasts.current == nil)
    }

    @Test
    func savePresetWithoutAnEditableFolderReturnsAnInlineError() async {
        let (model, _, _, scanner, _) = harness()
        await scanRoot(model, scanner, root: "/R")
        model.template = "tpl"
        model.setSelection("/R/B", .readOnly)

        let error = await model.savePreset(name: "p", existingPresets: [])

        #expect(error == "Select at least one editable folder before saving.")
    }

    @Test
    func savePresetOverwritesTheSameNameAndToastsOverwritten() async {
        let existing = Preset(
            name: "p", rootPath: "/R", template: "old", sandboxName: nil,
            clone: false, editable: ["Z"], readOnly: []
        )
        let (model, app, toasts, scanner, _) = harness()
        await scanRoot(model, scanner, root: "/R")
        model.template = "new"
        model.setSelection("/R/A", .editable)

        let error = await model.savePreset(name: "p", existingPresets: [existing])

        #expect(error == nil)
        #expect(app.config.presets.count == 1)
        #expect(app.config.presets[0].template == "new")
        #expect(app.config.presets[0].editable == ["A"])
        #expect(toasts.current?.message == "Preset \"p\" overwritten.")
    }

    @Test
    func canSavePresetTracksCommandReadiness() async {
        let (model, _, _, scanner, _) = harness()
        await scanRoot(model, scanner, root: "/R")
        #expect(model.canSavePreset == false)
        model.template = "tpl"
        #expect(model.canSavePreset == false)
        model.setSelection("/R/A", .editable)
        #expect(model.canSavePreset == true)
    }

    // -- load preset --

    @Test
    func loadPresetOnTheSameRootRestoresSelectionAndSettings() async {
        let (model, _, toasts, scanner, _) = harness()
        await scanRoot(model, scanner, root: "/R", children: ["/R/A", "/R/B"])
        model.template = "old"
        let preset = Preset(
            name: "p", rootPath: "/R", template: "t2", sandboxName: "s",
            clone: true, editable: ["A"], readOnly: ["B"]
        )

        await model.loadPreset(preset, maxDepth: 3, ignoreFolders: [])

        #expect(model.selection == ["/R/A": .editable, "/R/B": .readOnly])
        #expect(model.template == "t2")
        #expect(model.sandboxName == "s")
        #expect(model.clone == true)
        #expect(model.primary == nil)
        #expect(model.expanded.contains("/R"))
        #expect(toasts.current?.message == "Loaded preset \"p\".")
    }

    @Test
    func loadPresetOnADifferentRootRescansThenApplies() async {
        let fs = TempDirectory()
        let rootA = fs.makeDirectory("a")
        let rootB = fs.makeDirectory("b")
        let (model, app, toasts, scanner, _) = harness()
        await app.load()
        await scanRoot(model, scanner, root: rootA)
        scanner.setResult(
            ScannedTree(nodes: [Self.node(rootB, depth: 0), Self.node(rootB + "/X", depth: 1)]),
            for: rootB
        )
        let preset = Preset(
            name: "p", rootPath: rootB, template: "t", sandboxName: nil,
            clone: false, editable: ["X"], readOnly: []
        )

        await model.loadPreset(preset, maxDepth: 3, ignoreFolders: [])
        scanner.release(rootB)
        await model.quiesce()

        #expect(model.rootPath == rootB)
        #expect(model.selection == [rootB + "/X": .editable])
        #expect(model.template == "t")
        #expect(app.config.rootPath == rootB)
        #expect(toasts.current?.message == "Loaded preset \"p\".")
    }

    @Test
    func loadPresetWithAMissingRootToastsAndChangesNothing() async {
        let (model, _, toasts, scanner, _) = harness()
        await scanRoot(model, scanner, root: "/R", children: ["/R/A"])
        model.setSelection("/R/A", .editable)
        let preset = Preset(
            name: "p", rootPath: "/gone", template: "t", sandboxName: nil,
            clone: false, editable: ["X"], readOnly: []
        )

        await model.loadPreset(preset, maxDepth: 3, ignoreFolders: [])

        #expect(toasts.current?.message == "Not found: /gone")
        #expect(toasts.current?.isError == true)
        #expect(model.rootPath == "/R")
        #expect(model.selection == ["/R/A": .editable])
    }

    // -- delete preset --

    @Test
    func deletePresetRemovesAndToasts() async {
        let (model, app, toasts, _, _) = harness()
        await app.load()
        await app.update {
            $0.presets = [
                Preset(name: "a", rootPath: "/r", template: "t", sandboxName: nil, clone: false, editable: ["A"], readOnly: []),
                Preset(name: "b", rootPath: "/r", template: "t", sandboxName: nil, clone: false, editable: ["B"], readOnly: []),
            ]
        }

        await model.deletePreset(name: "a")

        #expect(app.config.presets.map(\.name) == ["b"])
        #expect(toasts.current?.message == "Deleted \"a\".")
    }

    // -- reveal --

    @Test
    func revealOfAValidDirectoryCallsTheRevealerWithoutAToast() {
        let fs = TempDirectory()
        let dir = fs.makeDirectory("proj")
        let toasts = ToastCenter()
        let revealer = StubRevealer()
        let (model, _, _, _, _) = harness(toasts: toasts, revealer: revealer)

        model.reveal(dir)

        #expect(revealer.revealed == [dir])
        #expect(toasts.current == nil)
    }

    @Test
    func revealOfAMissingPathToastsWithoutCallingTheRevealer() {
        let toasts = ToastCenter()
        let revealer = StubRevealer()
        let (model, _, _, _, _) = harness(toasts: toasts, revealer: revealer)

        model.reveal("/gone/dir")

        #expect(revealer.revealed.isEmpty)
        #expect(toasts.current?.message == "Folder not found: /gone/dir")
        #expect(toasts.current?.isError == true)
    }

    @Test
    func revealOfAFileToastsNotADirectory() {
        let fs = TempDirectory()
        let file = fs.makeFile("note.txt")
        let toasts = ToastCenter()
        let revealer = StubRevealer()
        let (model, _, _, _, _) = harness(toasts: toasts, revealer: revealer)

        model.reveal(file)

        #expect(revealer.revealed.isEmpty)
        #expect(toasts.current?.message == "Not a directory: \(file)")
    }

    @Test
    func aFailedRevealToastsAnError() {
        let fs = TempDirectory()
        let dir = fs.makeDirectory("proj")
        let toasts = ToastCenter()
        let revealer = StubRevealer(succeeds: false)
        let (model, _, _, _, _) = harness(toasts: toasts, revealer: revealer)

        model.reveal(dir)

        #expect(revealer.revealed == [dir])
        #expect(toasts.current?.isError == true)
    }
}
