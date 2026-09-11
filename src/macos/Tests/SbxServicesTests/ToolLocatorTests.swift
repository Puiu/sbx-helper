import Testing
import Foundation
@testable import SbxServices

private struct FakeCommandRunner: CommandRunning {
    let response: CommandResult
    func run(executable: String, arguments: [String], stdin: Data?, environment: [String: String], timeout: Duration, maxOutputBytes: Int) async -> CommandResult {
        response
    }
}

@Suite("ToolLocator")
struct ToolLocatorTests {
    @Test("SBX_HELPER_SBX_PATH wins when it exists, before anything else is checked")
    func envVarWins() async {
        let locator = ToolLocator(
            commandRunner: FakeCommandRunner(response: CommandResult(ok: false, exitCode: 1, stdout: "", stderr: "")),
            environment: ["SBX_HELPER_SBX_PATH": "/env/sbx"],
            configuredPath: "/configured/sbx",
            fixedProbePaths: ["/fixed/sbx"],
            fileExists: { $0 == "/env/sbx" || $0 == "/configured/sbx" || $0 == "/fixed/sbx" }
        )
        #expect(await locator.resolvedPath() == "/env/sbx")
    }

    @Test("falls through to the configured path when the env var doesn't exist on disk")
    func configuredPathIsSecond() async {
        let locator = ToolLocator(
            commandRunner: FakeCommandRunner(response: CommandResult(ok: false, exitCode: 1, stdout: "", stderr: "")),
            environment: ["SBX_HELPER_SBX_PATH": "/env/sbx"],
            configuredPath: "/configured/sbx",
            fixedProbePaths: ["/fixed/sbx"],
            fileExists: { $0 == "/configured/sbx" || $0 == "/fixed/sbx" }
        )
        #expect(await locator.resolvedPath() == "/configured/sbx")
    }

    @Test("falls through to the fixed probe paths in order")
    func fixedProbePathsInOrder() async {
        let locator = ToolLocator(
            commandRunner: FakeCommandRunner(response: CommandResult(ok: false, exitCode: 1, stdout: "", stderr: "")),
            environment: [:], configuredPath: nil,
            fixedProbePaths: ["/opt/homebrew/bin/sbx", "/usr/local/bin/sbx"],
            fileExists: { $0 == "/usr/local/bin/sbx" }
        )
        #expect(await locator.resolvedPath() == "/usr/local/bin/sbx")
    }

    @Test("falls through to a shell probe (command -v sbx) as the last resort")
    func shellProbeIsLastResort() async {
        let locator = ToolLocator(
            commandRunner: FakeCommandRunner(response: CommandResult(ok: true, exitCode: 0, stdout: "/asdf/shim/sbx\n", stderr: "")),
            environment: [:], configuredPath: nil, fixedProbePaths: [],
            fileExists: { $0 == "/asdf/shim/sbx" }
        )
        #expect(await locator.resolvedPath() == "/asdf/shim/sbx")
    }

    @Test("takes the LAST non-empty line of the shell probe's output, in case shell startup files print banners first")
    func shellProbeTakesLastLine() async {
        let locator = ToolLocator(
            commandRunner: FakeCommandRunner(response: CommandResult(
                ok: true, exitCode: 0, stdout: "Welcome to zsh\nsome banner noise\n/asdf/shim/sbx\n", stderr: ""
            )),
            environment: [:], configuredPath: nil, fixedProbePaths: [],
            fileExists: { $0 == "/asdf/shim/sbx" }
        )
        #expect(await locator.resolvedPath() == "/asdf/shim/sbx")
    }

    @Test("rejects a shell-probe result that doesn't exist on disk — a shell function or alias definition, say")
    func shellProbeResultMustExist() async {
        let locator = ToolLocator(
            commandRunner: FakeCommandRunner(response: CommandResult(
                ok: true, exitCode: 0, stdout: "sbx () {\n  command sbx-real \"$@\"\n}\n", stderr: ""
            )),
            environment: [:], configuredPath: nil, fixedProbePaths: [],
            fileExists: { _ in false }
        )
        #expect(await locator.resolvedPath() == nil)
    }

    @Test("returns nil when nothing resolves — never throws, never guesses")
    func nilWhenNothingResolves() async {
        let locator = ToolLocator(
            commandRunner: FakeCommandRunner(response: CommandResult(ok: false, exitCode: 1, stdout: "", stderr: "not found")),
            environment: [:], configuredPath: nil, fixedProbePaths: [],
            fileExists: { _ in false }
        )
        #expect(await locator.resolvedPath() == nil)
    }

    @Test("resolution is cached — a second call doesn't re-invoke the shell probe")
    func resolutionIsCached() async {
        actor CallCounter { var count = 0; func increment() { count += 1 } }
        let counter = CallCounter()
        struct CountingRunner: CommandRunning {
            let counter: CallCounter
            func run(executable: String, arguments: [String], stdin: Data?, environment: [String: String], timeout: Duration, maxOutputBytes: Int) async -> CommandResult {
                await counter.increment()
                return CommandResult(ok: true, exitCode: 0, stdout: "/asdf/sbx\n", stderr: "")
            }
        }
        let locator = ToolLocator(
            commandRunner: CountingRunner(counter: counter),
            environment: [:], configuredPath: nil, fixedProbePaths: [], fileExists: { _ in false }
        )
        _ = await locator.resolvedPath()
        _ = await locator.resolvedPath()
        #expect(await counter.count == 1)
    }

    @Test("child environment prepends the resolved directory plus the homebrew/local prefixes to PATH")
    func childEnvironmentPrependsPath() async {
        let locator = ToolLocator(
            commandRunner: FakeCommandRunner(response: CommandResult(ok: false, exitCode: 1, stdout: "", stderr: "")),
            environment: ["PATH": "/usr/bin:/bin"], configuredPath: "/custom/dir/sbx",
            fixedProbePaths: [], fileExists: { $0 == "/custom/dir/sbx" }
        )
        let env = await locator.childEnvironment()
        #expect(env["PATH"] == "/custom/dir:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    }
}
