// Native replacements for the two remaining Electron shell-outs:
// `pbcopy` -> NSPasteboard, `open <dir>` -> NSWorkspace. Ports
// src/electron/lib/terminal.mjs's copyToClipboard/revealInFinder.
import AppKit

public enum SystemServices {
    public static func copyToClipboard(_ text: String, pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// Opens `path` as its own Finder window — the same behavior as the JS's
    /// `open <dirPath>`, not a reveal-and-select within the parent.
    public static func reveal(_ path: String) -> Bool {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

/// A test seam over `SystemServices.copyToClipboard` — `SystemServices`
/// itself is a bare static enum with nothing to inject, and it imports
/// AppKit, which `SbxAppCore` must not pull into its model layer.
public protocol ClipboardWriting: Sendable {
    func write(_ text: String) -> Bool
}

public struct SystemClipboard: ClipboardWriting {
    public init() {}

    public func write(_ text: String) -> Bool {
        SystemServices.copyToClipboard(text)
    }
}

/// A test seam over `SystemServices.reveal` — same reasoning as
/// `ClipboardWriting`: the enum itself is static AppKit code with nothing
/// to inject, and `SbxAppCore` must not import AppKit directly.
public protocol FinderRevealing: Sendable {
    func reveal(_ path: String) -> Bool
}

public struct SystemFinder: FinderRevealing {
    public init() {}

    public func reveal(_ path: String) -> Bool {
        SystemServices.reveal(path)
    }
}
