// Ports src/electron/test/config.test.mjs (minus the preset relativize/
// absolutize case, which lives in RelativePathTests.swift).
import Foundation
import Testing
@testable import SbxKit

@Suite("defaultConfig")
struct DefaultConfigTests {
    @Test("includes an empty sandboxArgs map")
    func emptySandboxArgs() {
        #expect(defaultConfig().sandboxArgs == [:])
    }

    @Test("rootPath is ~/repos if it exists, else the home directory")
    func rootPathIsReposOrHome() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let reposDir = (home as NSString).appendingPathComponent("repos")
        var isDir: ObjCBool = false
        let reposExists = fm.fileExists(atPath: reposDir, isDirectory: &isDir) && isDir.boolValue
        #expect(defaultConfig().rootPath == (reposExists ? reposDir : home))
    }
}

@Suite("loadConfig / saveConfig")
struct ConfigCodecTests {
    @Test("writes and returns defaults when the file is missing")
    func writesDefaultsWhenMissing() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        let loaded = loadConfig(path)
        #expect(loaded.error == nil)
        #expect(loaded.config.defaultTemplate == defaultConfig().defaultTemplate)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("falls back to defaults on malformed JSON, without throwing")
    func fallsBackOnMalformedJSON() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        try! "{ not json".write(toFile: path, atomically: true, encoding: .utf8)
        let loaded = loadConfig(path)
        #expect(loaded.error != nil)
        #expect(loaded.config.presets == [])
    }

    @Test("round-trips through save/load")
    func roundTripsSaveLoad() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        var cfg = defaultConfig()
        cfg.rootPath = "/tmp/x"
        cfg.defaultTemplate = "tpl:v1"
        saveConfig(path, cfg)
        let loaded = loadConfig(path)
        #expect(loaded.config.rootPath == "/tmp/x")
        #expect(loaded.config.defaultTemplate == "tpl:v1")
    }

    @Test("saveConfig leaves no leftover temp file behind")
    func noLeftoverTempFile() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        saveConfig(path, defaultConfig())
        let leftovers = (try! FileManager.default.contentsOfDirectory(atPath: dir.path))
            .filter { $0 != "sbx-helper.json" }
        #expect(leftovers == [])
    }

    @Test("does not escape slashes in saved paths — a readable, hand-editable file")
    func doesNotEscapeSlashes() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        var cfg = defaultConfig()
        cfg.rootPath = "/Users/alexalbu/repos/nho"
        saveConfig(path, cfg)
        let raw = try! String(contentsOfFile: path, encoding: .utf8)
        #expect(!raw.contains("\\/"))
        #expect(raw.contains("/Users/alexalbu/repos/nho"))
    }

    // A hand-edited (or corrupted-but-still-valid-JSON) config with the
    // wrong type for a field used to propagate straight through a naive
    // `{...defaultConfig(), ...parsed}`-style merge — e.g. "presets": null
    // overriding the default [] and crashing the first array use.
    @Test("coerces a non-array presets value back to the default")
    func coercesNonArrayPresets() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        try! #"{"presets": null}"#.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(loadConfig(path).config.presets == [])
    }

    @Test("coerces a non-array recentRoots value back to the default")
    func coercesNonArrayRecentRoots() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        try! #"{"recentRoots": "not-an-array"}"#.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(loadConfig(path).config.recentRoots == [])
    }

    @Test("coerces a non-array ignoreFolders value back to the default")
    func coercesNonArrayIgnoreFolders() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        try! #"{"ignoreFolders": 42}"#.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(loadConfig(path).config.ignoreFolders == defaultConfig().ignoreFolders)
    }

    @Test("coerces a non-object sandboxArgs value back to the default")
    func coercesNonObjectSandboxArgs() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        try! #"{"sandboxArgs": ["not", "an", "object"]}"#.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(loadConfig(path).config.sandboxArgs == [:])
    }

    @Test("coerces a null sandboxArgs value back to the default")
    func coercesNullSandboxArgs() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        try! #"{"sandboxArgs": null}"#.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(loadConfig(path).config.sandboxArgs == [:])
    }

    // sandboxArgs stores a single quoted display string per sandbox name
    // (server.mjs: `config.sandboxArgs[name] = formatCommand(agentArgs)`),
    // not an array — PLAN.md originally had this wrong.
    @Test("decodes sandboxArgs as a name -> display-string map")
    func decodesSandboxArgsAsStringMap() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        try! #"{"sandboxArgs": {"my-sandbox": "--model opusplan"}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        #expect(loadConfig(path).config.sandboxArgs == ["my-sandbox": "--model opusplan"])
    }

    // Regression: countDroppedPresets only counted array *elements* that
    // failed to decode. If `presets` is present but isn't an array at all
    // (e.g. an object), the element-counting decode throws entirely and
    // reports 0 dropped — so isDegraded was false even though the presets
    // field was completely unusable and about to be silently wiped on the
    // next save.
    @Test("flags degradation when presets is present but not an array at all")
    func flagsDegradationForNonArrayPresetsShape() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        try! #"{"presets": {"a": {"name": "x"}}}"#.write(toFile: path, atomically: true, encoding: .utf8)
        let loaded = loadConfig(path)
        #expect(loaded.config.presets == [])
        #expect(loaded.isDegraded == true)
    }

    @Test("flags degradation when sandboxArgs is present but not an object at all")
    func flagsDegradationForNonObjectSandboxArgsShape() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        try! #"{"sandboxArgs": ["not", "an", "object"]}"#.write(toFile: path, atomically: true, encoding: .utf8)
        let loaded = loadConfig(path)
        #expect(loaded.config.sandboxArgs == [:])
        #expect(loaded.isDegraded == true)
    }

    @Test("does not flag degradation for a benign null presets/sandboxArgs value")
    func doesNotFlagDegradationForNull() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        try! #"{"presets": null, "sandboxArgs": null}"#.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(loadConfig(path).isDegraded == false)
    }

    @Test("a malformed preset in an otherwise good array is dropped, the rest survive")
    func dropsMalformedPreset() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        try! """
        {"presets": [
          {"name":"good","rootPath":"/root","template":"tpl","sandboxName":null,"clone":false,"editable":[],"readOnly":[]},
          "not-an-object",
          {"name":"also-good","rootPath":"/root","template":"tpl","sandboxName":null,"clone":false,"editable":[],"readOnly":[]}
        ]}
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let loaded = loadConfig(path)
        #expect(loaded.config.presets.map(\.name) == ["good", "also-good"])
        #expect(loaded.droppedPresets == 1)
        #expect(loaded.isDegraded == true)
    }

    @Test("the real Electron app's config file (no sandboxArgs key at all) decodes clean")
    func decodesRealElectronConfig() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        try! """
        {
          "rootPath": "/Users/alexalbu/repos/nho/24907-otp-samtykke",
          "recentRoots": ["/Users/alexalbu/repos/nho/24907-otp-samtykke", "/Users/alexalbu/repos/nho"],
          "defaultTemplate": "claude-sbx-dotnet10:v2",
          "agent": "claude",
          "maxDepth": 3,
          "ignoreFolders": [".git", "node_modules", "bin", "obj", ".vs", ".idea"],
          "port": 7777,
          "presets": []
        }
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let loaded = loadConfig(path)
        #expect(loaded.error == nil)
        #expect(loaded.config.rootPath == "/Users/alexalbu/repos/nho/24907-otp-samtykke")
        #expect(loaded.config.sandboxArgs == [:])
        #expect(loaded.isDegraded == false)
    }

    @Test("malformed JSON is preserved as .bak with the exact original bytes")
    func preservesMalformedJSONAsBak() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        let badBytes = "{ not json"
        try! badBytes.write(toFile: path, atomically: true, encoding: .utf8)
        let loaded = loadConfig(path)
        #expect(loaded.error != nil)
        #expect(loaded.config == defaultConfig())
        let bakPath = path + ".bak"
        #expect(FileManager.default.fileExists(atPath: bakPath))
        #expect(FileManager.default.fileExists(atPath: path) == false)
        let preserved = try! Data(contentsOf: URL(fileURLWithPath: bakPath))
        #expect(preserved == Data(badBytes.utf8))
    }

    @Test("a second malformed load overwrites a stale .bak with the latest bad bytes")
    func overwritesStaleBak() {
        let dir = TempDirectory()
        let path = dir.joined("sbx-helper.json")
        let bakPath = path + ".bak"
        try! "{ first bad".write(toFile: path, atomically: true, encoding: .utf8)
        _ = loadConfig(path)
        let secondBadBytes = "{ second bad!!"
        try! secondBadBytes.write(toFile: path, atomically: true, encoding: .utf8)
        _ = loadConfig(path)
        let preserved = try! Data(contentsOf: URL(fileURLWithPath: bakPath))
        #expect(preserved == Data(secondBadBytes.utf8))
    }

    @Test("valid and missing files create no .bak")
    func noBakForValidOrMissing() {
        let dir = TempDirectory()
        let validPath = dir.joined("valid.json")
        var cfg = defaultConfig()
        cfg.rootPath = "/tmp/x"
        saveConfig(validPath, cfg)
        _ = loadConfig(validPath)
        #expect(!FileManager.default.fileExists(atPath: validPath + ".bak"))
        let missingPath = dir.joined("missing.json")
        _ = loadConfig(missingPath)
        #expect(!FileManager.default.fileExists(atPath: missingPath + ".bak"))
    }
}

@Suite("resolveConfigPath")
struct ResolveConfigPathTests {
    @Test("honors SBX_HELPER_CONFIG when set")
    func honorsEnvOverride() {
        let path = resolveConfigPath(environment: ["SBX_HELPER_CONFIG": "/tmp/custom.json"], home: "/Users/x")
        #expect(path == "/tmp/custom.json")
    }

    @Test("defaults to the sbx-helper-swift Application Support path")
    func defaultsToApplicationSupport() {
        let path = resolveConfigPath(environment: [:], home: "/Users/x")
        #expect(path == "/Users/x/Library/Application Support/sbx-helper-swift/sbx-helper.json")
    }
}
