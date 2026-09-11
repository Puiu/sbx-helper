// Ports server.mjs's apiPresets (192-229) and apiScan root handling
// (155-175): preset validation/assembly/upsert/delete plus root resolution
// and recent-roots bookkeeping.
import Testing
@testable import SbxKit

struct PresetStoreTests {
    @Test
    func blankPresetNameIsRejected() {
        #expect(throws: SbxKitError.presetNameRequired) {
            try buildPreset(
                name: "   ", rootPath: "/root", template: "tpl", defaultTemplate: "tpl",
                sandboxName: nil, clone: false, editable: ["/root/A"], readOnly: []
            )
        }
    }

    @Test
    func savingWithoutAnEditableFolderIsRejected() {
        #expect(throws: SbxKitError.presetRequiresEditable) {
            try buildPreset(
                name: "p", rootPath: "/root", template: "tpl", defaultTemplate: "tpl",
                sandboxName: nil, clone: false, editable: [], readOnly: ["/root/B"]
            )
        }
    }

    @Test
    func blankTemplateFallsBackToTheDefault() throws {
        let preset = try buildPreset(
            name: "p", rootPath: "/root", template: "  ", defaultTemplate: "dflt",
            sandboxName: nil, clone: false, editable: ["/root/A"], readOnly: []
        )
        #expect(preset.template == "dflt")
    }

    @Test
    func templateIsTrimmed() throws {
        let preset = try buildPreset(
            name: "p", rootPath: "/root", template: "  tpl  ", defaultTemplate: "dflt",
            sandboxName: nil, clone: false, editable: ["/root/A"], readOnly: []
        )
        #expect(preset.template == "tpl")
    }

    @Test
    func blankSandboxNameBecomesNil() throws {
        let preset = try buildPreset(
            name: "p", rootPath: "/root", template: "tpl", defaultTemplate: "tpl",
            sandboxName: "", clone: false, editable: ["/root/A"], readOnly: []
        )
        #expect(preset.sandboxName == nil)
    }

    @Test
    func pathsAreStoredRelativeToTheRoot() throws {
        let preset = try buildPreset(
            name: "p", rootPath: "/root", template: "tpl", defaultTemplate: "tpl",
            sandboxName: "sbx", clone: true, editable: ["/root/A"], readOnly: ["/root/B"]
        )
        #expect(preset.editable == ["A"])
        #expect(preset.readOnly == ["B"])
        #expect(preset.sandboxName == "sbx")
        #expect(preset.clone == true)
    }

    @Test
    func upsertReplacesAnExistingPresetByName() {
        let existing = Preset(
            name: "p", rootPath: "/root", template: "old", sandboxName: nil,
            clone: false, editable: ["A"], readOnly: []
        )
        let replacement = Preset(
            name: "p", rootPath: "/root", template: "new", sandboxName: nil,
            clone: false, editable: ["B"], readOnly: []
        )
        let (result, overwritten) = upsertPreset(replacement, into: [existing])
        #expect(overwritten == true)
        #expect(result.count == 1)
        #expect(result[0].template == "new")
    }

    @Test
    func upsertAppendsANewPreset() {
        let preset = Preset(
            name: "new", rootPath: "/root", template: "tpl", sandboxName: nil,
            clone: false, editable: ["A"], readOnly: []
        )
        let (result, overwritten) = upsertPreset(preset, into: [])
        #expect(overwritten == false)
        #expect(result.map(\.name) == ["new"])
    }

    @Test
    func deleteRemovesOnlyTheNamedPreset() {
        let presets = [
            Preset(name: "a", rootPath: "/r", template: "t", sandboxName: nil, clone: false, editable: ["A"], readOnly: []),
            Preset(name: "b", rootPath: "/r", template: "t", sandboxName: nil, clone: false, editable: ["B"], readOnly: []),
        ]
        #expect(deletePreset(named: "a", from: presets).map(\.name) == ["b"])
    }

    @Test
    func blankRootIsRejected() {
        #expect(throws: SbxKitError.rootPathRequired) {
            try resolveRoot("   ", exists: { _ in true }, isDirectory: { _ in true })
        }
    }

    @Test
    func missingRootReportsNotFound() {
        #expect(throws: SbxKitError.pathNotFound(path: "/root/gone")) {
            try resolveRoot("/root/gone", exists: { _ in false }, isDirectory: { _ in false })
        }
    }

    @Test
    func fileRootReportsNotADirectory() {
        #expect(throws: SbxKitError.notADirectory(path: "/root/file")) {
            try resolveRoot("/root/file", exists: { _ in true }, isDirectory: { _ in false })
        }
    }

    @Test
    func directoryRootResolves() throws {
        #expect(try resolveRoot("/root/dir", exists: { _ in true }, isDirectory: { _ in true }) == "/root/dir")
    }

    @Test
    func recentRootsPrependsDedupesAndCaps() {
        let updated = recordRecentRoot("/c", in: ["/b", "/a"])
        #expect(updated.first == "/c")
        let deduped = recordRecentRoot("/a", in: ["/b", "/a"])
        #expect(deduped.first == "/a")
        #expect(deduped.filter({ $0 == "/a" }).count == 1)
        let capped = recordRecentRoot("/new", in: (0..<8).map { "/\($0)" })
        #expect(capped.count == 8)
        #expect(capped.first == "/new")
    }
}
