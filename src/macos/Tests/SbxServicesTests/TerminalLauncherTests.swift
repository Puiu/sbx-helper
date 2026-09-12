import Testing
import Foundation
@testable import SbxServices
import SbxKit

private actor RecordingRunner: CommandRunning {
    private(set) var calls: [(executable: String, arguments: [String], timeout: Duration)] = []
    private let scripted: [String: CommandResult] // keyed by executable
    init(scripted: [String: CommandResult]) { self.scripted = scripted }
    func run(executable: String, arguments: [String], stdin: Data?, environment: [String: String], timeout: Duration, maxOutputBytes: Int) async -> CommandResult {
        calls.append((executable, arguments, timeout))
        return scripted[executable] ?? CommandResult(ok: false, exitCode: 1, stdout: "", stderr: "no script")
    }
}

@Suite("TerminalLauncher")
struct TerminalLauncherTests {
    @Test("writes an executable run.command script that execs the formatted command")
    func writesRunScript() throws {
        let launcher = TerminalLauncher(commandRunner: RecordingRunner(scripted: [:]))
        let scriptPath = try launcher.writeRunScript(args: ["sbx", "run", "--name", "my sandbox"])
        let contents = try String(contentsOfFile: scriptPath, encoding: .utf8)
        #expect(contents == "#!/bin/sh\nexec sbx run --name 'my sandbox'\n")
        let attrs = try FileManager.default.attributesOfItem(atPath: scriptPath)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test("writeRunScript throws (rather than silently succeeding) when the script can't actually be written")
    func writeRunScriptThrowsOnWriteFailure() throws {
        let launcher = TerminalLauncher(commandRunner: RecordingRunner(scripted: [:]))
        let readOnlyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sbx-helper-readonly-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: readOnlyDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyDir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyDir) }

        #expect(throws: (any Error).self) {
            try launcher.writeRunScript(args: ["sbx", "run"], directory: readOnlyDir)
        }
    }

    @Test("escapes backslashes and double quotes for the AppleScript string literal")
    func escapesAppleScriptString() {
        let script = TerminalLauncher.appleScript(forScriptPath: "/tmp/a\"b\\c")
        #expect(script.contains("/tmp/a\\\"b\\\\c"))
    }

    @Test("succeeds via iTerm AppleScript when osascript succeeds")
    func succeedsViaAppleScript() async {
        let runner = RecordingRunner(scripted: ["/usr/bin/osascript": CommandResult(ok: true, exitCode: 0, stdout: "", stderr: "")])
        let launcher = TerminalLauncher(commandRunner: runner)
        let result = await launcher.launch(args: ["sbx", "run", "--name", "x"])
        #expect(result.ok == true)
        #expect(result.method == "iterm-applescript")
        let calls = await runner.calls
        #expect(calls.count == 1)
    }

    @Test("falls back to open -a iTerm when AppleScript fails")
    func fallsBackToOpenIterm() async {
        let runner = RecordingRunner(scripted: [
            "/usr/bin/osascript": CommandResult(ok: false, exitCode: 1, stdout: "", stderr: "no iTerm"),
            "/usr/bin/open": CommandResult(ok: true, exitCode: 0, stdout: "", stderr: ""),
        ])
        let launcher = TerminalLauncher(commandRunner: runner)
        let result = await launcher.launch(args: ["sbx", "run", "--name", "x"])
        #expect(result.ok == true)
        #expect(result.method == "iterm-open")
        let calls = await runner.calls
        #expect(calls.map(\.executable) == ["/usr/bin/osascript", "/usr/bin/open"])
        #expect(calls[1].arguments.first == "-a" && calls[1].arguments[1] == "iTerm")
    }

    @Test("gives the AppleScript attempt a generous timeout, longer than the 10s default")
    func appleScriptGetsAGenerousTimeout() async {
        // A cold iTerm launch plus a pending TCC Automation consent prompt
        // (which blocks osascript until a human clicks it) routinely exceeds
        // 10s. Too short a timeout makes launch() give up and fall through
        // to `open -a iTerm` while the AppleScript attempt is still pending
        // — risking two terminal windows (and two attached `sbx run`
        // sessions) once the original AppleScript eventually lands.
        let runner = RecordingRunner(scripted: ["/usr/bin/osascript": CommandResult(ok: true, exitCode: 0, stdout: "", stderr: "")])
        let launcher = TerminalLauncher(commandRunner: runner)
        _ = await launcher.launch(args: ["sbx", "run", "--name", "x"])
        let calls = await runner.calls
        guard let osascriptCall = calls.first(where: { $0.executable == "/usr/bin/osascript" }) else {
            Issue.record("expected an osascript call")
            return
        }
        #expect(osascriptCall.timeout > .seconds(10))
    }

    @Test("falls back to Terminal.app and finally reports failure with a message")
    func fallsBackToTerminalThenFails() async {
        struct AlwaysFailRunner: CommandRunning {
            func run(executable: String, arguments: [String], stdin: Data?, environment: [String: String], timeout: Duration, maxOutputBytes: Int) async -> CommandResult {
                CommandResult(ok: false, exitCode: 1, stdout: "", stderr: "\(executable) failed")
            }
        }
        let launcher = TerminalLauncher(commandRunner: AlwaysFailRunner())
        let result = await launcher.launch(args: ["sbx", "run", "--name", "x"])
        #expect(result.ok == false)
        #expect(result.error != nil)
    }

    @Test("the stale-temp sweep removes only old sbx-helper-* dirs")
    func sweepRemovesOnlyStaleAppDirs() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("sweep-test-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }

        let stale = (tmp as NSString).appendingPathComponent("sbx-helper-old")
        let fresh = (tmp as NSString).appendingPathComponent("sbx-helper-new")
        let other = (tmp as NSString).appendingPathComponent("not-ours-old")
        for dir in [stale, fresh, other] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let oldDate = Date().addingTimeInterval(-48 * 3600)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: stale)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: other)

        TerminalLauncher.sweepStaleTempDirs(
            atPath: tmp, olderThan: Date().addingTimeInterval(-24 * 3600))

        #expect(fm.fileExists(atPath: stale) == false)
        #expect(fm.fileExists(atPath: fresh) == true)
        #expect(fm.fileExists(atPath: other) == true)
    }
}
