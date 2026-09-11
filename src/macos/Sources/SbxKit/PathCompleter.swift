// Ports src/electron/lib/scan.mjs — completePath. Path autocomplete for the
// "change root" dialog: splits `prefix` at its last "/" into a base
// directory and a partial name, and returns up to `limit` absolute paths of
// that directory's subfolders whose name starts with the partial
// (case-insensitive).
import Foundation

public struct PathCompleter: Sendable {
    public var ignoreFolders: Set<String>
    public var limit: Int

    public init(ignoreFolders: Set<String>, limit: Int = 25) {
        self.ignoreFolders = ignoreFolders
        self.limit = limit
    }

    /// Dot-folders are skipped unless the partial itself starts with ".",
    /// matching how you'd expect to reach them by typing. Returns [] for a
    /// non-absolute prefix or an unreadable/missing base directory — there
    /// is nothing wrong to report, the user is mid-typing.
    public func completePath(_ prefix: String) -> [String] {
        guard prefix.hasPrefix("/") else { return [] }

        let endsWithSlash = prefix.hasSuffix("/")
        let baseDir: String
        let partial: String
        if endsWithSlash {
            let withoutSlash = String(prefix.dropLast())
            baseDir = withoutSlash.isEmpty ? "/" : withoutSlash
            partial = ""
        } else {
            baseDir = (prefix as NSString).deletingLastPathComponent
            partial = (prefix as NSString).lastPathComponent
        }
        let partialLower = partial.lowercased()
        let showDotDirs = partial.hasPrefix(".")

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: baseDir, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }

        var names: [String] = []
        for entryURL in entries {
            let name = entryURL.lastPathComponent
            if !showDotDirs, name.hasPrefix(".") { continue }
            if ignoreFolders.contains(name) { continue }
            guard name.lowercased().hasPrefix(partialLower) else { continue }

            let values = try? entryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            guard values?.isDirectory == true else { continue }

            names.append(name)
        }

        // Same deliberate Finder-style divergence as DirectoryScanner (see
        // PLAN.md) — the JS uses plain `.localeCompare` here too.
        return names
            .sorted(by: FinderOrder.precedes)
            .prefix(limit)
            .map { (baseDir as NSString).appendingPathComponent($0) }
    }
}
