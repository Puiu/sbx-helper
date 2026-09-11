// Model-level integration test for the Phase 5 acceptance path: save a
// preset → flush to disk → fresh ConfigStore/AppModel from the same file →
// load the preset into a fresh BuilderModel. Asserts the on-disk JSON holds
// relative paths and the restored selection/template/name/clone match. This
// is the closest the suite can get to the "save, quit, relaunch, load"
// checklist — PLAN.md forbids SwiftUI-importing tests and true relaunch
// isn't scriptable here, so the `.app` sighted pass stays manual.
import Testing
import Foundation
import SbxKit
import SbxServices
@testable import SbxAppCore

@MainActor
struct PresetRoundTripTests {
    @Test
    func saveFlushReloadAndLoadRestoresTheFullSelection() async throws {
        let fs = TempDirectory()
        let root = fs.makeDirectory("repos")
        fs.makeDirectory("repos/alpha")
        fs.makeDirectory("repos/beta")
        let configPath = (fs.path as NSString).appendingPathComponent("sbx-helper.json")

        // -- session one: select, save, flush --
        let storeOne = ConfigStore(path: configPath)
        let appOne = AppModel(configStore: storeOne)
        await appOne.load()
        let scanner = StubScanner()
        let toasts = ToastCenter()
        let builderOne = BuilderModel(
            scanner: scanner,
            toasts: toasts,
            templateLister: StubTemplateLister(),
            launcher: StubLauncher(),
            clipboard: StubClipboard(),
            persistTemplate: { [appOne] template in await appOne.update { $0.defaultTemplate = template } },
            mutateConfig: { [appOne] transform in await appOne.update(transform) }
        )
        builderOne.template = "tpl"
        builderOne.sandboxName = "sbx1"
        builderOne.clone = true
        scanner.setResult(
            ScannedTree(nodes: [
                TreeNode(path: root, name: root, depth: 0, isGitRepo: false, unreadable: false),
            ]),
            for: root
        )
        scanner.release(root)
        builderOne.scan(root: root, maxDepth: 3, ignoreFolders: [])
        await builderOne.quiesce()
        builderOne.setSelection(root + "/alpha", .editable)
        builderOne.setSelection(root + "/beta", .readOnly)
        let saveError = await builderOne.savePreset(name: "work", existingPresets: appOne.config.presets)
        #expect(saveError == nil)
        await storeOne.flush()

        // The on-disk preset holds paths relative to its root, exactly as
        // the Electron schema does — never absolute.
        let raw = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(raw.contains("\"alpha\""))
        #expect(!raw.contains(root + "/alpha"))

        // -- session two: fresh store + models from the same file --
        let storeTwo = ConfigStore(path: configPath)
        let appTwo = AppModel(configStore: storeTwo)
        await appTwo.load()
        #expect(appTwo.configBanner == nil)
        #expect(appTwo.config.presets.count == 1)
        let builderTwo = BuilderModel(
            scanner: scanner,
            toasts: ToastCenter(),
            templateLister: StubTemplateLister(),
            launcher: StubLauncher(),
            clipboard: StubClipboard(),
            persistTemplate: { [appTwo] template in await appTwo.update { $0.defaultTemplate = template } },
            mutateConfig: { [appTwo] transform in await appTwo.update(transform) }
        )
        let tree = ScannedTree(nodes: [
            TreeNode(path: root, name: root, depth: 0, isGitRepo: false, unreadable: false),
            TreeNode(path: root + "/alpha", name: "alpha", depth: 1, isGitRepo: false, unreadable: false),
            TreeNode(path: root + "/beta", name: "beta", depth: 1, isGitRepo: false, unreadable: false),
        ])
        scanner.setResult(tree, for: root)
        scanner.release(root)
        builderTwo.scan(root: root, maxDepth: 3, ignoreFolders: [])
        await builderTwo.quiesce()

        await builderTwo.loadPreset(appTwo.config.presets[0], maxDepth: 3, ignoreFolders: [])

        #expect(builderTwo.selection == [root + "/alpha": .editable, root + "/beta": .readOnly])
        #expect(builderTwo.template == "tpl")
        #expect(builderTwo.sandboxName == "sbx1")
        #expect(builderTwo.clone == true)
    }
}
