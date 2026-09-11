// Ports src/electron/lib/terminal.mjs's launchInTerminal. The only
// interpolated AppleScript value is a path this app generated itself
// (mkdtemp-style, 0700) — the real (already-quoted) command lives in that
// script instead, avoiding two stacked layers of shell + AppleScript string
// escaping. Keep this byte-for-byte with the JS: a quoting bug here is live
// shell injection into the user's own terminal.
import Foundation
import SbxKit

public struct LaunchResult: Sendable, Equatable {
    public var ok: Bool
    public var method: String?
    public var error: String?

    public init(ok: Bool, method: String? = nil, error: String? = nil) {
        self.ok = ok
        self.method = method
        self.error = error
    }
}

public protocol TerminalLaunching: Sendable {
    func launch(args: [String]) async -> LaunchResult
}

enum TerminalLauncherError: Error, Sendable, Equatable {
    case couldNotWriteScript(String)
}

public struct TerminalLauncher: TerminalLaunching {
    private let commandRunner: CommandRunning

    public init(commandRunner: CommandRunning) {
        self.commandRunner = commandRunner
    }

    static func escapeAppleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func appleScript(forScriptPath path: String) -> String {
        let escaped = escapeAppleScriptString(path)
        return """
        tell application "iTerm"
          create window with default profile
          tell current session of current window
            write text "source \\"\(escaped)\\""
          end tell
        end tell
        """
    }

    /// `args` still carries its leading "sbx" element — the script's own
    /// interactive shell resolves `sbx` via PATH, so no absolute-path
    /// resolution happens here.
    ///
    /// `directory`, when given, is used as-is (no creation, no permission
    /// change) instead of a fresh `mkdtemp`-style directory — a test-only
    /// seam for forcing a write failure deterministically.
    func writeRunScript(args: [String], directory: String? = nil) throws -> String {
        let dir: String
        if let directory {
            dir = directory
        } else {
            dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("sbx-helper-\(UUID().uuidString)")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let scriptPath = (dir as NSString).appendingPathComponent("run.command")
        let content = "#!/bin/sh\nexec \(formatCommand(args))\n"
        guard FileManager.default.createFile(atPath: scriptPath, contents: Data(content.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw TerminalLauncherError.couldNotWriteScript(scriptPath)
        }
        return scriptPath
    }

    public func launch(args: [String]) async -> LaunchResult {
        sweepStaleTempDirs()

        let scriptPath: String
        do { scriptPath = try writeRunScript(args: args) }
        catch { return LaunchResult(ok: false, method: nil, error: "\(error)") }

        // A generous, explicit timeout rather than the 10s convenience
        // default: a cold iTerm launch plus a pending TCC Automation
        // consent prompt (which blocks osascript until a human clicks it)
        // routinely exceeds 10s. Giving up too early here risks falling
        // through to `open -a iTerm` while the original AppleScript attempt
        // is still pending — two terminal windows once it eventually lands.
        let viaAppleScript = await commandRunner.run(
            executable: "/usr/bin/osascript", arguments: ["-e", Self.appleScript(forScriptPath: scriptPath)],
            stdin: nil, environment: ProcessInfo.processInfo.environment,
            timeout: .seconds(120), maxOutputBytes: 1_000_000
        )
        if viaAppleScript.ok { return LaunchResult(ok: true, method: "iterm-applescript", error: nil) }

        let viaOpenIterm = await commandRunner.run(executable: "/usr/bin/open", arguments: ["-a", "iTerm", scriptPath])
        if viaOpenIterm.ok { return LaunchResult(ok: true, method: "iterm-open", error: nil) }

        let viaOpenTerminal = await commandRunner.run(executable: "/usr/bin/open", arguments: ["-a", "Terminal", scriptPath])
        if viaOpenTerminal.ok { return LaunchResult(ok: true, method: "terminal-open", error: nil) }

        let message = !viaAppleScript.stderr.isEmpty ? viaAppleScript.stderr
            : !viaOpenTerminal.stderr.isEmpty ? viaOpenTerminal.stderr
            : "Could not open a terminal window."
        return LaunchResult(ok: false, method: nil, error: message)
    }

    /// Best-effort launch-time sweep of temp dirs this app leaked in past
    /// runs (the JS version leaks one per launch, forever). Immediate
    /// deletion of the CURRENT run's dir isn't possible — iTerm/Terminal
    /// sources the script asynchronously — so this only ever removes dirs
    /// old enough (24h) to be certainly done with.
    private func sweepStaleTempDirs() {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory()
        guard let entries = try? fm.contentsOfDirectory(atPath: tmp) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for entry in entries where entry.hasPrefix("sbx-helper-") {
            let full = (tmp as NSString).appendingPathComponent(entry)
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let modified = attrs[.modificationDate] as? Date, modified < cutoff else { continue }
            try? fm.removeItem(atPath: full)
        }
    }
}
