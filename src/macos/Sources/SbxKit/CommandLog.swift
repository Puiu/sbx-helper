// Bounded record of recent `sbx` subprocess invocations — the backing
// store for the Sandboxes tab's live "sbx commands" debug section. Pure
// data (Foundation only): `SbxCLI` appends from its `invoke()` path and
// `SandboxesModel` snapshots it for the view. Bounded both in entries and
// per-output chars so a chatty or failing `sbx` can't grow memory without
// limit; truncation keeps the head of each stream, where the
// parse-diagnosing bytes are.
import Foundation

/// One recorded `sbx` invocation: the display command plus the captured
/// result. `exitCode` is nil when nothing spawned (tool not found).
public struct SbxInvocation: Sendable, Equatable, Identifiable {
    public let id: UInt64
    public let command: String
    public let ok: Bool
    public let exitCode: Int32?
    public let stdout: String
    public let stderr: String

    public init(id: UInt64, command: String, ok: Bool, exitCode: Int32?, stdout: String, stderr: String) {
        self.id = id
        self.command = command
        self.ok = ok
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    /// One-line result for the log row header.
    public var statusText: String {
        if let exitCode { return "exit \(exitCode)" }
        return "not started"
    }
}

/// Append-only, newest-last log with a hard entry cap.
public struct SbxInvocationLog: Sendable, Equatable {
    public static let maxEntries = 50
    public static let maxOutputChars = 4_000

    public private(set) var entries: [SbxInvocation] = []

    public init() {}

    public mutating func append(_ entry: SbxInvocation) {
        let stored = SbxInvocation(
            id: entry.id, command: entry.command, ok: entry.ok, exitCode: entry.exitCode,
            stdout: Self.truncate(entry.stdout), stderr: Self.truncate(entry.stderr)
        )
        entries.append(stored)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    /// Keeps the head of `text` — `sbx --json` responses read top-down, so
    /// the tail is what's expendable when bounding memory.
    public static func truncate(_ text: String) -> String {
        guard text.count > maxOutputChars else { return text }
        return String(text.prefix(maxOutputChars)) + "\n… (truncated, \(text.count) chars total)"
    }
}
