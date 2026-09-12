// Ports src/electron/server.mjs's apiRun (lines 231-274) pre-launch path
// checks. The Node server validated every workspace path was absolute and
// existed on disk before spawning `sbx`, so a preset naming a folder deleted
// since it was saved fails with "Folder not found: X" rather than `sbx`
// failing cryptically. That server layer doesn't exist in the native app, so
// this moves the same checks into SbxKit as a pure function.
import Foundation

/// Validates every path in `paths`, in order, positionally: the first path
/// that fails (relative, then missing) is the one reported — not the "worst"
/// failure across the whole list. `exists` mirrors Node's `fs.existsSync`
/// (existence only, not directory-ness — the reveal-in-Finder path is the
/// one that additionally checks directory-ness, and that isn't this).
/// Overlap is not checked here: `buildArgs` already enforces
/// `findAnyConflict` as its own precondition.
public func validateLaunchPaths(
    _ paths: [String],
    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) throws(SbxKitError) {
    for path in paths {
        guard path.hasPrefix("/") else { throw .notAbsolutePath }
        guard exists(path) else { throw .folderNotFound(path: path) }
    }
}

/// Ports the Settings sheet's `sbx` location validation (Phase 8): a
/// user-typed `sbx` path must be absolute and resolve to something
/// `ToolLocator` would accept — existing AND executable (the locator gates
/// on `isExecutableFile`, so validation must too, or a "successful" Save
/// leaves the banner up). Errors are binary-specific cases, not the
/// workspace/folder ones, since the sheet surfaces them verbatim.
public func validateSbxPath(
    _ path: String,
    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
) throws(SbxKitError) {
    guard path.hasPrefix("/") else { throw .sbxPathMustBeAbsolute }
    guard exists(path), isExecutable(path) else { throw .sbxNotFound(path: path) }
}

/// Ports src/electron/server.mjs's apiReveal (284-300) path checks: the
/// reveal endpoint, unlike apiRun, additionally requires directory-ness
/// (a file path is rejected, not opened). Order matches the JS: absolute,
/// then existence ("Folder not found: X" — shared with apiRun), then
/// directory-ness.
public func validateRevealPath(
    _ path: String,
    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    isDirectory: (String) -> Bool = { var isDir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
) throws(SbxKitError) {
    guard path.hasPrefix("/") else { throw .revealPathMustBeAbsolute }
    guard exists(path) else { throw .folderNotFound(path: path) }
    guard isDirectory(path) else { throw .notADirectory(path: path) }
}
