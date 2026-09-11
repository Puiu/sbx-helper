// Ports src/electron/lib/config.mjs — the data shapes. See ConfigCodec.swift
// for load/save.
import Foundation

/// A saved Builder selection: template, name, clone flag, and editable/
/// read-only paths stored relative to `rootPath` (see RelativePath.swift).
public struct Preset: Sendable, Equatable, Codable, Identifiable {
    public var name: String
    public var rootPath: String
    public var template: String
    public var sandboxName: String?
    public var clone: Bool
    public var editable: [String]
    public var readOnly: [String]

    public var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, rootPath, template, sandboxName, clone, editable, readOnly
    }

    public init(
        name: String, rootPath: String, template: String, sandboxName: String?, clone: Bool,
        editable: [String], readOnly: [String]
    ) {
        self.name = name
        self.rootPath = rootPath
        self.template = template
        self.sandboxName = sandboxName
        self.clone = clone
        self.editable = editable
        self.readOnly = readOnly
    }

    // A naive synthesized Codable conformance regresses here: one
    // wrong-typed field would throw and take the *entire* presets array
    // down with it (see ConfigCodec.swift / PLAN.md). Every field is
    // decoded leniently, falling back rather than throwing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenient(.name, "")
        rootPath = c.lenient(.rootPath, "")
        template = c.lenient(.template, "")
        sandboxName = c.lenient(.sandboxName, nil as String?)
        clone = c.lenient(.clone, false)
        editable = c.lenientArray(.editable, [])
        readOnly = c.lenientArray(.readOnly, [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(rootPath, forKey: .rootPath)
        try c.encode(template, forKey: .template)
        try c.encodeIfPresent(sandboxName, forKey: .sandboxName)
        try c.encode(clone, forKey: .clone)
        try c.encode(editable, forKey: .editable)
        try c.encode(readOnly, forKey: .readOnly)
    }
}

/// The persisted app config. `sandboxArgs` stores a single quoted display
/// string per sandbox name (`server.mjs`: `config.sandboxArgs[name] =
/// formatCommand(agentArgs)`), not an array of tokens.
public struct AppConfig: Sendable, Equatable, Codable {
    public var rootPath: String
    public var recentRoots: [String]
    public var defaultTemplate: String
    public var agent: String
    public var maxDepth: Int
    public var ignoreFolders: [String]
    public var port: Int
    public var presets: [Preset]
    public var sandboxArgs: [String: String]
    /// New field, absent from the Electron schema — resolved location of
    /// the `sbx` binary, set via a Settings sheet (SbxServices, Phase 2).
    public var sbxPath: String?

    private enum CodingKeys: String, CodingKey {
        case rootPath, recentRoots, defaultTemplate, agent, maxDepth, ignoreFolders, port, presets, sandboxArgs, sbxPath
    }

    public init(
        rootPath: String, recentRoots: [String], defaultTemplate: String, agent: String,
        maxDepth: Int, ignoreFolders: [String], port: Int, presets: [Preset],
        sandboxArgs: [String: String], sbxPath: String?
    ) {
        self.rootPath = rootPath
        self.recentRoots = recentRoots
        self.defaultTemplate = defaultTemplate
        self.agent = agent
        self.maxDepth = maxDepth
        self.ignoreFolders = ignoreFolders
        self.port = port
        self.presets = presets
        self.sandboxArgs = sandboxArgs
        self.sbxPath = sbxPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = defaultConfig()
        rootPath = c.lenient(.rootPath, d.rootPath)
        recentRoots = c.lenientArray(.recentRoots, d.recentRoots)
        defaultTemplate = c.lenient(.defaultTemplate, d.defaultTemplate)
        agent = c.lenient(.agent, d.agent)
        maxDepth = c.lenient(.maxDepth, d.maxDepth)
        ignoreFolders = c.lenientArray(.ignoreFolders, d.ignoreFolders)
        port = c.lenient(.port, d.port)
        presets = c.lenientArray(.presets, d.presets)
        sandboxArgs = c.lenientMap(.sandboxArgs)
        sbxPath = c.lenient(.sbxPath, nil as String?)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rootPath, forKey: .rootPath)
        try c.encode(recentRoots, forKey: .recentRoots)
        try c.encode(defaultTemplate, forKey: .defaultTemplate)
        try c.encode(agent, forKey: .agent)
        try c.encode(maxDepth, forKey: .maxDepth)
        try c.encode(ignoreFolders, forKey: .ignoreFolders)
        try c.encode(port, forKey: .port)
        try c.encode(presets, forKey: .presets)
        try c.encode(sandboxArgs, forKey: .sandboxArgs)
        try c.encodeIfPresent(sbxPath, forKey: .sbxPath)
    }
}

/// The result of `loadConfig` — the config plus whether anything had to be
/// coerced or dropped, so the caller knows to back up the file before its
/// next write.
public struct LoadedConfig: Sendable {
    public let config: AppConfig
    public let error: String?
    public let droppedPresets: Int
    /// True when `presets` or `sandboxArgs` was present in the raw JSON with
    /// a fundamentally wrong shape (not `null`, not the expected array/
    /// object) — a case `droppedPresets` can't count an element total for,
    /// but which is just as much data loss as a per-element drop.
    public let hadUnrecoverableFieldShape: Bool

    public init(config: AppConfig, error: String?, droppedPresets: Int, hadUnrecoverableFieldShape: Bool = false) {
        self.config = config
        self.error = error
        self.droppedPresets = droppedPresets
        self.hadUnrecoverableFieldShape = hadUnrecoverableFieldShape
    }

    public var isDegraded: Bool { error != nil || droppedPresets > 0 || hadUnrecoverableFieldShape }
}
