// Per-test temp directory for filesystem tests — no shared root between
// tests, so no `.serialized` is needed. `deinit` resets permissions before
// removal (a `chmod 000` fixture would otherwise leave an undeletable temp
// dir behind for the rest of the session if a test fails before restoring
// them itself).
import Foundation

final class TempDirectory {
    let path: String
    let url: URL

    init(prefix: String = "sbx-helper-test-") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir
        path = dir.path
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) -> String {
        let full = joined(relativePath)
        try! FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    @discardableResult
    func makeFile(_ relativePath: String, contents: String = "") -> String {
        let full = joined(relativePath)
        FileManager.default.createFile(atPath: full, contents: Data(contents.utf8))
        return full
    }

    @discardableResult
    func makeSymlink(_ relativePath: String, to target: String) -> String {
        let full = joined(relativePath)
        try! FileManager.default.createSymbolicLink(atPath: full, withDestinationPath: target)
        return full
    }

    func joined(_ relativePath: String) -> String {
        (path as NSString).appendingPathComponent(relativePath)
    }

    deinit {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(atPath: path) {
            for case let item as String in enumerator {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: joined(item))
            }
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        try? fm.removeItem(atPath: path)
    }
}
