// Ports src/electron/lib/config.mjs — defaultConfig, loadConfig, saveConfig,
// and the SBX_HELPER_CONFIG env-override resolution.
import Foundation

/// The default config. `rootPath` deliberately does not port the JS's
/// `process.cwd()` — that's only sensible for a shell-launched server; a
/// GUI-launched .app's cwd is `/`. Uses `~/repos` if it exists, else `~`.
public func defaultConfig() -> AppConfig {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    let reposDir = (home as NSString).appendingPathComponent("repos")
    var isDirectory: ObjCBool = false
    let reposExists = fm.fileExists(atPath: reposDir, isDirectory: &isDirectory) && isDirectory.boolValue

    return AppConfig(
        rootPath: reposExists ? reposDir : home,
        recentRoots: [],
        defaultTemplate: "claude-sbx-dotnet10:v2",
        agent: "claude",
        maxDepth: 3,
        ignoreFolders: [".git", "node_modules", "bin", "obj", ".vs", ".idea"],
        port: 7777,
        presets: [],
        sandboxArgs: [:],
        sbxPath: nil
    )
}

/// `~/Library/Application Support/sbx-helper-swift/sbx-helper.json`,
/// overridable by `SBX_HELPER_CONFIG` (tests, dev). Deliberately not the
/// Electron app's `sbx-helper/` directory — the schema is identical so
/// presets can be copied over by hand, but the two apps can't clobber each
/// other while both exist.
///
/// A pure function over a passed-in environment dictionary, not `getenv`
/// internally — swift-testing runs tests in parallel, and a `setenv` in one
/// test would corrupt another.
public func resolveConfigPath(environment: [String: String], home: String) -> String {
    if let override = environment["SBX_HELPER_CONFIG"], !override.isEmpty {
        return override
    }
    return (home as NSString).appendingPathComponent("Library/Application Support/sbx-helper-swift/sbx-helper.json")
}

private func countDroppedPresets(in data: Data) -> Int {
    struct Envelope: Decodable { let presets: [Failable<Preset>]? }
    guard let raw = try? JSONDecoder().decode(Envelope.self, from: data) else { return 0 }
    return (raw.presets ?? []).filter { $0.value == nil }.count
}

/// True when `presets`/`sandboxArgs` is present in the raw JSON with a shape
/// that isn't `null` and isn't the expected container type at all (so
/// `countDroppedPresets`'s element-level decode can't even attempt it, and
/// silently reports 0 dropped even though the whole field was unusable).
private func hasUnrecoverableFieldShape(in data: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    if let raw = object["presets"], !(raw is NSNull), !(raw is [Any]) { return true }
    if let raw = object["sandboxArgs"], !(raw is NSNull), !(raw is [String: Any]) { return true }
    return false
}

/// Missing config -> write and return defaults. Malformed JSON, or a
/// present-but-unreadable file -> defaults + a non-fatal error message.
/// A hand-edited config with the wrong type for a field falls back to that
/// field's default rather than throwing (see AppConfig's lenient decode);
/// `droppedPresets` reports how many preset entries didn't survive.
public func loadConfig(_ path: String) -> LoadedConfig {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else {
        let fresh = defaultConfig()
        saveConfig(path, fresh)
        return LoadedConfig(config: fresh, error: nil, droppedPresets: 0)
    }
    guard let data = fm.contents(atPath: path) else {
        return LoadedConfig(config: defaultConfig(), error: "Could not read \(path)", droppedPresets: 0)
    }
    do {
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        return LoadedConfig(
            config: config,
            error: nil,
            droppedPresets: countDroppedPresets(in: data),
            hadUnrecoverableFieldShape: hasUnrecoverableFieldShape(in: data)
        )
    } catch {
        try? fm.removeItem(atPath: path + ".bak")
        try? fm.moveItem(atPath: path, toPath: path + ".bak")
        return LoadedConfig(config: defaultConfig(), error: "\(error)", droppedPresets: 0)
    }
}

/// Writes via `Data.write(to:options:[.atomic])` — the same same-directory
/// temp-file + `rename(2)` the JS hand-rolls, so a crash or full disk
/// mid-write can't leave a truncated config behind. `.withoutEscapingSlashes`
/// keeps every path in this hand-editable file readable (JSONEncoder
/// escapes `/` as `\/` by default).
public func saveConfig(_ path: String, _ config: AppConfig) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard var data = try? encoder.encode(config) else { return }
    data.append(contentsOf: "\n".utf8)
    try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])
}
