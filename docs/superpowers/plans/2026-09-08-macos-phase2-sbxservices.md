# macOS Phase 2 — SbxServices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Electron app's process-spawning layer (`lib/sandboxes.mjs`, `lib/templates.mjs`, `lib/terminal.mjs`, the `pbcopy`/`open` shell-outs, and config load/save/debounce) into a new `SbxServices` Swift library, built on top of the already-complete `SbxKit` (Phase 1) pure-logic layer.

**Architecture:** Six files in `Sources/SbxServices/`. `ProcessRunner` (an `actor`) is the one place that spawns a child process and is never allowed to throw or deadlock. `ToolLocator` (an `actor`) resolves and caches the absolute path to the `sbx` binary, since a GUI-launched `.app` doesn't inherit a shell's `PATH`. `SbxCLI` (an `actor`) composes both to build `sbx` argv (via `SbxKit`'s already-ported `SandboxCommands`/`SbxModels`) and turn the result into typed success/failure. `TerminalLauncher` and `SystemServices` are the two remaining native replacements for shell-outs (`osascript`/`open -a iTerm`/`open -a Terminal`, and `pbcopy`/`open <dir>` respectively). `ConfigStore` (an `actor`) wraps `SbxKit`'s already-ported `loadConfig`/`saveConfig` with an in-memory copy and debounced disk writes. Three protocols (`CommandRunning`, `TerminalLaunching`, and the `Result`-based `SbxCLI` surface itself) are the seams later UI code (Phase 3+) will inject fakes through.

**Tech Stack:** Swift 6.2 (CLT only, no Xcode), Foundation `Process`/`Pipe`, AppKit (`NSPasteboard`, `NSWorkspace`), `import Testing` (swift-testing, bundled in CLT — no XCTest, no package dependency).

**Spec:** `src/macos/PLAN.md` (the "SbxServices" and "Phase 2" sections, plus the "What disappears, and what must survive" section) — this plan implements exactly that, translated into concrete files/signatures/tests grounded in the real `src/electron/lib/*.mjs` source being ported and its existing test coverage (`src/electron/test/server-sandboxes.test.mjs`, `src/electron/test-fixtures/sbx-shim.js`).

## Global Constraints

- **No new package dependencies.** `import Testing` ships in the CLT toolchain; adding the `swift-testing` package would conflict. Everything else is Foundation/AppKit.
- **`Scripts/test.sh`, never plain `swift test`** — the CLT/swift-testing rpath workaround (see `PLAN.md` Phase 0). Every verification step in this plan uses it.
- **`Process`/`Pipe`/`FileHandle` are non-`Sendable`**; confine them to one actor (`ProcessRunner`) and use `final class ... : @unchecked Sendable` + `NSLock` only for the two small buffer/flag types that must cross the readability-handler boundary — never anywhere else.
- **Never pass `"sbx"` as `arguments[0]`.** `SbxKit`'s `buildStopArgs`/`buildRemoveArgs`/`buildPolicyAddArgs`/`buildPolicyRemoveArgs`/`buildRunExistingArgs` all return an array that **starts with the literal string `"sbx"`** (it doubles as the display/preview command). Any code that actually spawns via `ProcessRunner` (which takes a separate `executable:` path) must pass `Array(built.dropFirst())` as `arguments:`. The one exception is `TerminalLauncher`, which writes the **full** array (including `"sbx"`) verbatim into the `.command` script, because that script runs under the user's own interactive shell where `sbx` is on `PATH` — see `PLAN.md`'s "ToolLocator — the biggest behavioral break" section.
- **Test fixtures are never SPM bundle resources.** `Tests/SbxKitTests/Support/ParityCorpus.swift` documents why: "Phase 0 found CLT/SwiftPM doing surprising things to the test target, and `Bundle.module` is one more thing that can break for reasons unrelated to the code under test." The shim script in this plan is located via `#filePath`, the same way.
- **`SbxCLI` methods never throw** — they return `Result<T, SbxCLIFailure>`, mirroring the JS `{ ok, error }` / never-throws contract for `runSbx`/`listSandboxes`/etc.
- **Re-validate the sandbox name on every mutating call, never cached** (`requireKnownSandbox`), and **re-validate `removable` before a policy `rm`** — both call a fresh `sbx ls`/`policy ls` each time. This is the load-bearing security property carried over from `src/electron/CLAUDE.md`.

---

## File Structure

```
src/macos/
  Package.swift                              MODIFY — add SbxServices + SbxServicesTests targets
  Sources/SbxServices/
    ProcessRunner.swift                       NEW — CommandResult, CommandRunning, actor ProcessRunner
    ToolLocator.swift                         NEW — actor ToolLocator
    SbxCLI.swift                              NEW — SbxCLIFailure, actor SbxCLI
    TerminalLauncher.swift                    NEW — LaunchResult, TerminalLaunching, struct TerminalLauncher
    SystemServices.swift                      NEW — enum SystemServices
    ConfigStore.swift                         NEW — actor ConfigStore
  Sources/SbxHelperApp/
    SbxHelperApp.swift                        MODIFY — drop PhaseZeroView
    PhaseZeroProbes.swift                     DELETE — superseded by ProcessRunner + TerminalLauncher
    SbxServicesProbe.swift                    NEW (throwaway) — the Phase 2 milestone view
  Tests/SbxServicesTests/
    Fixtures/sbx-shim.sh                      NEW — fake `sbx` binary, invoked by absolute path
    Support/ShimHarness.swift                 NEW — locates + drives the shim, per-test temp log
    ProcessRunnerTests.swift                  NEW
    ToolLocatorTests.swift                    NEW
    SbxCLITests.swift                         NEW
    TerminalLauncherTests.swift               NEW
    SystemServicesTests.swift                 NEW
    ConfigStoreTests.swift                    NEW
  PLAN.md                                     MODIFY — Status section, at the end
```

---

### Task 1: Package.swift wiring + shim fixture + test harness

**Files:**
- Modify: `src/macos/Package.swift`
- Create: `src/macos/Tests/SbxServicesTests/Fixtures/sbx-shim.sh`
- Create: `src/macos/Tests/SbxServicesTests/Support/ShimHarness.swift`
- Test: `src/macos/Tests/SbxServicesTests/ShimHarnessSmokeTests.swift`

**Interfaces:**
- Produces: `struct ShimHarness { let shimPath: String; let logPath: String; var environment: [String: String]; init() throws; func loggedArgv() -> [[String]] }` — every later test file in this plan uses this.

- [ ] **Step 1: Modify `Package.swift`** to add the new library target, point `SbxHelperApp` at it, and add the new test target:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "sbx-helper",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .target(
            name: "SbxKit",
            path: "Sources/SbxKit"
        ),
        .target(
            name: "SbxServices",
            dependencies: ["SbxKit"],
            path: "Sources/SbxServices"
        ),
        .executableTarget(
            name: "SbxHelperApp",
            dependencies: ["SbxKit", "SbxServices"],
            path: "Sources/SbxHelperApp",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "SbxKitTests",
            dependencies: ["SbxKit"],
            path: "Tests/SbxKitTests"
        ),
        .testTarget(
            name: "SbxServicesTests",
            dependencies: ["SbxServices"],
            path: "Tests/SbxServicesTests"
        ),
    ]
)
```

- [ ] **Step 2: Create the shim fixture** `src/macos/Tests/SbxServicesTests/Fixtures/sbx-shim.sh`:

```sh
#!/bin/sh
# Fake `sbx` binary for SbxServicesTests, invoked directly by absolute path
# (ProcessRunner takes an absolute executable, not a PATH lookup — unlike
# the Electron test's test-fixtures/sbx-shim.js, this fixture never needs
# PATH manipulation). Logs the argv of EVERY invocation (reads included) as
# one JSON array per line to $SBX_SHIM_LOG, matching the JS fixture's
# logging contract, then answers canned JSON for `ls --json` and
# `policy ls <name> --json`, exits 0 for the mutating subcommands
# (stop / rm / policy allow|deny|rm), and exits 1 for anything else.
#
# Env knobs:
#   SBX_SHIM_FAIL_LS=1        -> `ls --json` exits 1 with a stderr message.
#   SBX_SHIM_OUTPUT_BYTES=N   -> print N 'x' bytes to stdout first (output-cap tests).
#   SBX_SHIM_SLEEP_SECONDS=N  -> sleep N seconds before responding (timeout tests).
#   SBX_SHIM_IGNORE_TERM=1    -> ignore SIGTERM. Combined with SLEEP_SECONDS this
#                                execs `sleep` after the trap so the ignored
#                                disposition (which POSIX preserves across exec,
#                                unlike other traps) actually reaches the pid
#                                ProcessRunner sends SIGTERM to — otherwise only
#                                this shell would ignore it, sleep would still die,
#                                and the shell would just keep waiting on nothing.

log() {
  json="["
  first=1
  for a in "$@"; do
    esc=$(printf '%s' "$a" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if [ "$first" = 1 ]; then first=0; else json="$json,"; fi
    json="$json\"$esc\""
  done
  json="$json]"
  printf '%s\n' "$json" >> "$SBX_SHIM_LOG"
}

log "$@"

if [ -n "$SBX_SHIM_IGNORE_TERM" ]; then
  trap '' TERM
  if [ -n "$SBX_SHIM_SLEEP_SECONDS" ]; then
    exec sleep "$SBX_SHIM_SLEEP_SECONDS"
  fi
fi

if [ -n "$SBX_SHIM_SLEEP_SECONDS" ]; then
  sleep "$SBX_SHIM_SLEEP_SECONDS"
fi

if [ -n "$SBX_SHIM_OUTPUT_BYTES" ]; then
  head -c "$SBX_SHIM_OUTPUT_BYTES" /dev/zero | tr '\0' 'x'
fi

if [ "$1" = "read-stdin" ]; then
  cat
  exit 0
fi

if [ "$1" = "ls" ]; then
  case " $* " in
    *" --json "*)
      if [ -n "$SBX_SHIM_FAIL_LS" ]; then
        echo "sbx: simulated failure (SBX_SHIM_FAIL_LS)" >&2
        exit 1
      fi
      cat <<'JSON'
{"sandboxes":[
  {"name":"test-sandbox-1","id":"id-1","agent":"claude","status":"running","workspaces":["/tmp/ws1"],"ports":[]},
  {"name":"test-sandbox-2","id":"id-2","agent":"opencode","status":"stopped","workspaces":["/tmp/ws2"],"ports":[]}
]}
JSON
      exit 0
      ;;
  esac
fi

if [ "$1" = "policy" ] && [ "$2" = "ls" ]; then
  name="$3"
  cat <<JSON
{"rules":[
  {"id":"removable-rule-id","name":"removable-rule-id","scope":"sandbox:$name","resource_type":"network","decision":"deny","resources":["ads.example.com"],"origin":"local","status":"active","editable":true},
  {"id":"default-ai-services","name":"default-ai-services","scope":"global","resource_type":"network","decision":"allow","resources":["api.anthropic.com:443"],"origin":"local","status":"active","editable":true}
]}
JSON
  exit 0
fi

if [ "$1" = "template" ] && [ "$2" = "ls" ]; then
  cat <<'TABLE'
REPOSITORY                    TAG
claude-sbx-dotnet10            v2
claude-sbx-python              v1
TABLE
  exit 0
fi

case "$1" in
  stop) exit 0 ;;
  rm) exit 0 ;;
  policy)
    case "$2" in
      allow|deny|rm) exit 0 ;;
    esac
    ;;
esac

exit 1
```

Make it executable: `chmod +x src/macos/Tests/SbxServicesTests/Fixtures/sbx-shim.sh` (Git may not preserve the bit on checkout on every machine, which is exactly why `ShimHarness.init()` below re-`chmod`s it defensively every time).

- [ ] **Step 3: Create the harness** `src/macos/Tests/SbxServicesTests/Support/ShimHarness.swift`:

```swift
// Locates and drives Tests/SbxServicesTests/Fixtures/sbx-shim.sh via its
// source-relative path — NOT an SPM bundle resource. See
// Tests/SbxKitTests/Support/ParityCorpus.swift for why (Bundle.module is
// unreliable under bare CLT per the Phase 0 findings in PLAN.md).
import Foundation

struct ShimHarness {
    let shimPath: String
    let logPath: String
    var environment: [String: String]

    init(sourceFile: StaticString = #filePath) throws {
        let thisFile = "\(sourceFile)"
        let supportDir = (thisFile as NSString).deletingLastPathComponent
        let testsDir = (supportDir as NSString).deletingLastPathComponent
        shimPath = (testsDir as NSString).appendingPathComponent("Fixtures/sbx-shim.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimPath)

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sbx-shim-log-\(UUID().uuidString)")
        logPath = logURL.path
        FileManager.default.createFile(atPath: logPath, contents: Data())

        environment = ["SBX_SHIM_LOG": logPath]
    }

    /// Every logged invocation's argv, in call order, as `["ls", "--json"]`-shaped arrays.
    func loggedArgv() -> [[String]] {
        guard let contents = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n").compactMap { line -> [String]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String].self, from: data)
        }
    }
}
```

- [ ] **Step 4: Write the scaffold smoke test** `src/macos/Tests/SbxServicesTests/ShimHarnessSmokeTests.swift` — proves the target, the shim, and the harness all actually work together before anything else is built on top of them:

```swift
import Testing
import Foundation

@Suite("ShimHarness scaffold")
struct ShimHarnessSmokeTests {
    @Test("the shim exits 0 for a mutating subcommand and logs its argv")
    func mutatingCommandLogsArgv() throws {
        let harness = try ShimHarness()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: harness.shimPath)
        process.arguments = ["stop", "some-sandbox"]
        process.environment = harness.environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(harness.loggedArgv() == [["stop", "some-sandbox"]])
    }

    @Test("the shim exits 1 for an unrecognized subcommand")
    func unknownCommandExitsNonZero() throws {
        let harness = try ShimHarness()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: harness.shimPath)
        process.arguments = ["bogus"]
        process.environment = harness.environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 1)
    }
}
```

- [ ] **Step 5: Run it** — `cd src/macos && ./Scripts/test.sh --filter ShimHarnessSmokeTests`
  Expected: 2 tests pass. (If `swift build` fails first because `Sources/SbxServices/` is empty, add a placeholder `// intentionally empty until Task 2` comment file — SwiftPM requires at least one source file per target.)

- [ ] **Step 6: Commit**

```bash
git add src/macos/Package.swift src/macos/Tests/SbxServicesTests
git commit -m "macos: scaffold SbxServices target and shim test harness"
```

---

### Task 2: ProcessRunner

**Files:**
- Create: `src/macos/Sources/SbxServices/ProcessRunner.swift`
- Test: `src/macos/Tests/SbxServicesTests/ProcessRunnerTests.swift`

**Interfaces:**
- Consumes: `ShimHarness` (Task 1).
- Produces:
  ```swift
  public struct CommandResult: Sendable, Equatable {
      public var ok: Bool
      public var exitCode: Int32?
      public var stdout: String
      public var stderr: String
      public var timedOut: Bool
  }
  public protocol CommandRunning: Sendable {
      func run(executable: String, arguments: [String], stdin: Data?, environment: [String: String], timeout: Duration, maxOutputBytes: Int) async -> CommandResult
  }
  public extension CommandRunning {
      func run(executable: String, arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> CommandResult
  }
  public actor ProcessRunner: CommandRunning { public init() }
  ```
  Every later task that spawns a process depends on `CommandRunning`/`ProcessRunner`.

- [ ] **Step 1: Write the failing tests** — `src/macos/Tests/SbxServicesTests/ProcessRunnerTests.swift`:

```swift
import Testing
import Foundation
@testable import SbxServices

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("captures stdout and a zero exit code")
    func successfulRun() async throws {
        let harness = try ShimHarness()
        let runner = ProcessRunner()
        let result = await runner.run(
            executable: harness.shimPath, arguments: ["stop", "test-sandbox-1"],
            stdin: nil, environment: harness.environment, timeout: .seconds(5), maxOutputBytes: 1_000_000
        )
        #expect(result.ok == true)
        #expect(result.exitCode == 0)
        #expect(harness.loggedArgv() == [["stop", "test-sandbox-1"]])
    }

    @Test("a non-zero exit reports ok == false with the exit code")
    func nonZeroExit() async throws {
        let harness = try ShimHarness()
        let runner = ProcessRunner()
        let result = await runner.run(
            executable: harness.shimPath, arguments: ["bogus-subcommand"],
            stdin: nil, environment: harness.environment, timeout: .seconds(5), maxOutputBytes: 1_000_000
        )
        #expect(result.ok == false)
        #expect(result.exitCode == 1)
    }

    @Test("a missing executable never throws — reports failure in the result")
    func missingExecutable() async {
        let runner = ProcessRunner()
        let result = await runner.run(
            executable: "/no/such/binary-\(UUID().uuidString)", arguments: [],
            stdin: nil, environment: [:], timeout: .seconds(5), maxOutputBytes: 1_000_000
        )
        #expect(result.ok == false)
        #expect(result.exitCode == nil)
        #expect(!result.stderr.isEmpty)
    }

    @Test("keeps draining past the output cap instead of deadlocking")
    func outputCapDoesNotDeadlock() async throws {
        let harness = try ShimHarness()
        let runner = ProcessRunner()
        var env = harness.environment
        env["SBX_SHIM_OUTPUT_BYTES"] = "500000" // well past Pipe's ~64KB kernel buffer
        let result = await runner.run(
            executable: harness.shimPath, arguments: ["stop", "big-output-sandbox"],
            stdin: nil, environment: env, timeout: .seconds(5), maxOutputBytes: 1_000
        )
        #expect(result.ok == true)
        #expect(result.stdout.utf8.count <= 1_000)
    }

    @Test("escalates to SIGKILL when the child ignores SIGTERM, and reports timedOut promptly")
    func timeoutEscalatesToSigkill() async throws {
        let harness = try ShimHarness()
        let runner = ProcessRunner()
        var env = harness.environment
        env["SBX_SHIM_IGNORE_TERM"] = "1"
        env["SBX_SHIM_SLEEP_SECONDS"] = "30"
        let start = ContinuousClock.now
        let result = await runner.run(
            executable: harness.shimPath, arguments: ["stop", "wedged-sandbox"],
            stdin: nil, environment: env, timeout: .milliseconds(300), maxOutputBytes: 1_000_000
        )
        let elapsed = ContinuousClock.now - start
        #expect(result.ok == false)
        #expect(result.timedOut == true)
        #expect(elapsed < .seconds(2))
    }

    @Test("delivers stdin bytes to the child")
    func deliversStdin() async throws {
        let harness = try ShimHarness()
        let runner = ProcessRunner()
        let result = await runner.run(
            executable: harness.shimPath, arguments: ["read-stdin"],
            stdin: Data("hello from swift".utf8), environment: harness.environment,
            timeout: .seconds(5), maxOutputBytes: 1_000_000
        )
        #expect(result.ok == true)
        #expect(result.stdout == "hello from swift")
    }

    @Test("a cancelled calling task terminates the child")
    func cancellationTerminatesChild() async throws {
        let harness = try ShimHarness()
        let runner = ProcessRunner()
        var env = harness.environment
        env["SBX_SHIM_SLEEP_SECONDS"] = "30"
        let task = Task {
            await runner.run(
                executable: harness.shimPath, arguments: ["stop", "cancel-me"],
                stdin: nil, environment: env, timeout: .seconds(60), maxOutputBytes: 1_000_000
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        #expect(result.ok == false)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `./Scripts/test.sh --filter ProcessRunnerTests`
  Expected: FAIL — `ProcessRunner`/`CommandResult`/`CommandRunning` don't exist yet.

- [ ] **Step 3: Implement** `src/macos/Sources/SbxServices/ProcessRunner.swift`:

```swift
// Ports the `runSbx` contract from src/electron/lib/sandboxes.mjs (spawn +
// timeout + kill escalation + output cap) into a reusable, general-purpose
// process runner — the `node:child_process.spawn` replacement every other
// SbxServices file spawns through. Never throws, matching the JS contract:
// a UI that must always render *something* can't have a process failure
// become an unhandled exception.
import Foundation

public struct CommandResult: Sendable, Equatable {
    public var ok: Bool
    public var exitCode: Int32?
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(ok: Bool, exitCode: Int32?, stdout: String, stderr: String, timedOut: Bool = false) {
        self.ok = ok
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol CommandRunning: Sendable {
    func run(
        executable: String, arguments: [String], stdin: Data?,
        environment: [String: String], timeout: Duration, maxOutputBytes: Int
    ) async -> CommandResult
}

public extension CommandRunning {
    func run(
        executable: String, arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> CommandResult {
        await run(
            executable: executable, arguments: arguments, stdin: nil,
            environment: environment, timeout: .seconds(10), maxOutputBytes: 1_000_000
        )
    }
}

/// Guards a byte buffer that's appended to from an arbitrary readability-handler
/// queue and read back from the calling actor. `NSLock` rather than an actor
/// because `FileHandle.readabilityHandler` fires synchronously off-actor and
/// can't `await` its way onto one.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap: Int

    init(cap: Int) { self.cap = cap }

    /// Always call this for every chunk read, even once `cap` is hit — the
    /// caller must keep *draining* the pipe (via `handle.availableData`) or
    /// the child deadlocks the moment it fills the ~64KB kernel pipe buffer.
    /// Only the accumulation into `data` stops; the read itself never does.
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count < cap { data.append(chunk) }
    }

    var snapshot: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

/// Exactly-once guard shared between the natural-termination path and the
/// timeout path — whichever reaches `trySettle()` first resolves the
/// continuation; the other becomes a no-op.
private final class Settled: @unchecked Sendable {
    private let lock = NSLock()
    private var isSettled = false
    func trySettle() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isSettled { return false }
        isSettled = true
        return true
    }
}

public actor ProcessRunner: CommandRunning {
    public init() {}

    public func run(
        executable: String, arguments: [String], stdin: Data?,
        environment: [String: String], timeout: Duration, maxOutputBytes: Int
    ) async -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdinPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        }

        let stdoutBuffer = OutputBuffer(cap: maxOutputBytes)
        let stderrBuffer = OutputBuffer(cap: maxOutputBytes)

        // Installed before `run()`, and always fully drained regardless of
        // `cap` — see OutputBuffer.append.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stdoutBuffer.append(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stderrBuffer.append(chunk) }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(ok: false, exitCode: nil, stdout: "", stderr: "\(error.localizedDescription)")
        }

        if let stdin, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }

        let pid = process.processIdentifier // captured first — see PLAN.md's ProcessRunner traps
        let settled = Settled()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
                let timeoutTask = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled, settled.trySettle() else { return }
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    kill(pid, SIGTERM)
                    let stderrText = String(data: stderrBuffer.snapshot, encoding: .utf8) ?? ""
                    continuation.resume(returning: CommandResult(
                        ok: false, exitCode: nil,
                        stdout: String(data: stdoutBuffer.snapshot, encoding: .utf8) ?? "",
                        stderr: stderrText.isEmpty ? "Timed out waiting for sbx." : stderrText,
                        timedOut: true
                    ))
                    // Give up waiting but still don't leave it running: escalate
                    // to SIGKILL if the child ignores SIGTERM. unref-equivalent —
                    // this detached task outliving the caller is intentional.
                    Task.detached {
                        try? await Task.sleep(for: .seconds(2))
                        kill(pid, SIGKILL)
                    }
                }

                process.terminationHandler = { proc in
                    guard settled.trySettle() else { return }
                    timeoutTask.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: CommandResult(
                        ok: proc.terminationStatus == 0,
                        exitCode: proc.terminationStatus,
                        stdout: String(data: stdoutBuffer.snapshot, encoding: .utf8) ?? "",
                        stderr: String(data: stderrBuffer.snapshot, encoding: .utf8) ?? ""
                    ))
                }
            }
        } onCancel: {
            kill(pid, SIGTERM)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — `./Scripts/test.sh --filter ProcessRunnerTests`
  Expected: all 7 tests PASS. If the timeout test is flaky under load, that's real signal — don't loosen the assertion silently; note it and re-run once before concluding it's environmental.

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/SbxServices/ProcessRunner.swift src/macos/Tests/SbxServicesTests/ProcessRunnerTests.swift
git commit -m "macos: add SbxServices/ProcessRunner"
```

---

### Task 3: ToolLocator

**Files:**
- Create: `src/macos/Sources/SbxServices/ToolLocator.swift`
- Test: `src/macos/Tests/SbxServicesTests/ToolLocatorTests.swift`

**Interfaces:**
- Consumes: `CommandRunning`, `CommandResult` (Task 2).
- Produces:
  ```swift
  public actor ToolLocator {
      public static let defaultProbePaths: [String]
      public init(commandRunner: CommandRunning, environment: [String: String], configuredPath: String?, fixedProbePaths: [String] = ToolLocator.defaultProbePaths, fileExists: @escaping @Sendable (String) -> Bool = ...)
      public func resolvedPath() async -> String?
      public func childEnvironment() async -> [String: String]
  }
  ```
  `SbxCLI` (Task 4) depends on both methods.

- [ ] **Step 1: Write the failing tests** — `src/macos/Tests/SbxServicesTests/ToolLocatorTests.swift`:

```swift
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
            fileExists: { _ in false }
        )
        #expect(await locator.resolvedPath() == "/asdf/shim/sbx")
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
```

- [ ] **Step 2: Run to verify failure** — `./Scripts/test.sh --filter ToolLocatorTests`
  Expected: FAIL — `ToolLocator` doesn't exist yet.

- [ ] **Step 3: Implement** `src/macos/Sources/SbxServices/ToolLocator.swift`:

```swift
// Resolves the absolute path to the `sbx` binary once per launch and caches
// it. A GUI-launched .app gets launchd's minimal PATH
// (/usr/bin:/bin:/usr/sbin:/sbin) — /opt/homebrew/bin is NOT on it — and
// Foundation's Process does no PATH search of its own, so `executableURL`
// must always be absolute. See PLAN.md's "ToolLocator" section for the
// five-tier resolution order this ports.
import Foundation

public actor ToolLocator {
    public static let defaultProbePaths: [String] = [
        "/opt/homebrew/bin/sbx",
        "/usr/local/bin/sbx",
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/sbx"),
        "/usr/bin/sbx",
    ]

    private let commandRunner: CommandRunning
    private let environment: [String: String]
    private let configuredPath: String?
    private let fixedProbePaths: [String]
    private let fileExists: @Sendable (String) -> Bool
    private var cached: String??

    public init(
        commandRunner: CommandRunning,
        environment: [String: String],
        configuredPath: String?,
        fixedProbePaths: [String] = ToolLocator.defaultProbePaths,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.commandRunner = commandRunner
        self.environment = environment
        self.configuredPath = configuredPath
        self.fixedProbePaths = fixedProbePaths
        self.fileExists = fileExists
    }

    /// Resolves once, caches the result (including a `nil` "not found") for
    /// the rest of this actor's lifetime.
    public func resolvedPath() async -> String? {
        if let cached { return cached }
        let result = await resolve()
        cached = result
        return result
    }

    private func resolve() async -> String? {
        if let envPath = environment["SBX_HELPER_SBX_PATH"], !envPath.isEmpty, fileExists(envPath) {
            return envPath
        }
        if let configuredPath, !configuredPath.isEmpty, fileExists(configuredPath) {
            return configuredPath
        }
        for path in fixedProbePaths where fileExists(path) {
            return path
        }
        let probe = await commandRunner.run(
            executable: "/bin/zsh", arguments: ["-lc", "command -v sbx"],
            stdin: nil, environment: environment, timeout: .seconds(2), maxOutputBytes: 4_096
        )
        guard probe.ok else { return nil }
        let trimmed = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The child environment for every `sbx` invocation: inherits
    /// `environment`, then prepends the resolved binary's own directory plus
    /// the two common prefixes — `sbx` shells out to `docker` itself, which
    /// lives in the same prefix.
    public func childEnvironment() async -> [String: String] {
        var env = environment
        var prefix: [String] = []
        if let resolved = await resolvedPath() {
            prefix.append((resolved as NSString).deletingLastPathComponent)
        }
        prefix.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        let existing = env["PATH"] ?? ""
        env["PATH"] = (prefix + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }
}
```

- [ ] **Step 4: Run to verify pass** — `./Scripts/test.sh --filter ToolLocatorTests`
  Expected: all 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/SbxServices/ToolLocator.swift src/macos/Tests/SbxServicesTests/ToolLocatorTests.swift
git commit -m "macos: add SbxServices/ToolLocator"
```

---

### Task 4: SbxCLI

**Files:**
- Create: `src/macos/Sources/SbxServices/SbxCLI.swift`
- Test: `src/macos/Tests/SbxServicesTests/SbxCLITests.swift`

**Interfaces:**
- Consumes: `CommandRunning`/`ProcessRunner` (Task 2), `ToolLocator` (Task 3), `ShimHarness` (Task 1), and from `SbxKit`: `Sandbox`, `PolicyRule`, `Decision`, `SbxKitError`, `parseSandboxLs`, `parseNetworkRules`, `parseTemplateLs`, `buildStopArgs`, `buildRemoveArgs`, `buildRunExistingArgs`, `buildPolicyAddArgs`, `buildPolicyRemoveArgs`.
- Produces:
  ```swift
  public enum SbxCLIFailure: Error, Sendable, Equatable {
      case toolNotFound
      case infrastructure(String)
      case unknownSandbox(String)
      case ruleNotRemovable(String)
      case invalid(SbxKitError)
      case commandFailed(String)
  }
  public actor SbxCLI {
      public init(commandRunner: CommandRunning, toolLocator: ToolLocator, timeout: Duration = .seconds(10))
      public func listSandboxes() async -> Result<[Sandbox], SbxCLIFailure>
      public func listTemplates() async -> [String]
      public func listNetworkRules(name: String) async -> Result<[PolicyRule], SbxCLIFailure>
      public func stop(name: String) async -> Result<Void, SbxCLIFailure>
      public func remove(name: String) async -> Result<Void, SbxCLIFailure>
      public func runExisting(name: String, agentArgs: [String]) async -> Result<[String], SbxCLIFailure>
      public func addPolicy(name: String, decision: Decision, resources: [String]) async -> Result<[PolicyRule], SbxCLIFailure>
      public func removePolicy(name: String, ruleId: String?, resource: String?) async -> Result<Void, SbxCLIFailure>
  }
  ```
  Later phases' `SandboxesModel`/`BuilderModel` (Phase 4/6/7) depend on this whole surface.

- [ ] **Step 1: Write the failing tests** — `src/macos/Tests/SbxServicesTests/SbxCLITests.swift`:

```swift
import Testing
import Foundation
@testable import SbxServices
import SbxKit

@Suite("SbxCLI")
struct SbxCLITests {
    func makeCLI(_ harness: ShimHarness) -> SbxCLI {
        var env = harness.environment
        env["SBX_HELPER_SBX_PATH"] = harness.shimPath
        let locator = ToolLocator(
            commandRunner: ProcessRunner(), environment: env, configuredPath: nil,
            fileExists: { $0 == harness.shimPath }
        )
        return SbxCLI(commandRunner: ProcessRunner(), toolLocator: locator)
    }

    @Test("listSandboxes parses the shim's canned ls --json output")
    func listSandboxesParses() async throws {
        let cli = makeCLI(try ShimHarness())
        guard case .success(let sandboxes) = await cli.listSandboxes() else {
            Issue.record("expected success")
            return
        }
        #expect(sandboxes.map(\.name).sorted() == ["test-sandbox-1", "test-sandbox-2"])
        let running = sandboxes.first { $0.name == "test-sandbox-1" }
        #expect(running?.agent == "claude")
        #expect(running?.status == "running")
    }

    @Test("listSandboxes reports an infrastructure failure when sbx ls itself fails")
    func listSandboxesInfraFailure() async throws {
        let harness = try ShimHarness()
        var env = harness.environment
        env["SBX_SHIM_FAIL_LS"] = "1"
        env["SBX_HELPER_SBX_PATH"] = harness.shimPath
        let locator = ToolLocator(commandRunner: ProcessRunner(), environment: env, configuredPath: nil, fileExists: { $0 == harness.shimPath })
        let cli = SbxCLI(commandRunner: ProcessRunner(), toolLocator: locator)
        guard case .failure(.infrastructure) = await cli.listSandboxes() else {
            Issue.record("expected .infrastructure")
            return
        }
    }

    @Test("listNetworkRules classifies sandbox-scoped rules as removable, global rules as not")
    func listNetworkRulesClassifies() async throws {
        let cli = makeCLI(try ShimHarness())
        guard case .success(let rules) = await cli.listNetworkRules(name: "test-sandbox-1") else {
            Issue.record("expected success")
            return
        }
        #expect(rules.first { $0.id == "removable-rule-id" }?.removable == true)
        #expect(rules.first { $0.id == "default-ai-services" }?.removable == false)
    }

    @Test("listNetworkRules rejects an unknown sandbox without spawning policy ls for it")
    func listNetworkRulesRejectsUnknown() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .failure(.unknownSandbox) = await cli.listNetworkRules(name: "no-such-sandbox") else {
            Issue.record("expected .unknownSandbox")
            return
        }
        let policyLsForBogus = harness.loggedArgv().contains {
            $0.first == "policy" && $0.dropFirst().first == "ls" && $0.dropFirst(2).first == "no-such-sandbox"
        }
        #expect(!policyLsForBogus)
    }

    @Test("stop spawns exactly sbx stop <name>")
    func stopSpawnsExactArgv() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .success = await cli.stop(name: "test-sandbox-1") else {
            Issue.record("expected success")
            return
        }
        #expect(harness.loggedArgv().filter { $0.first == "stop" } == [["stop", "test-sandbox-1"]])
    }

    @Test("stop rejects an unknown sandbox name without spawning stop")
    func stopRejectsUnknown() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .failure(.unknownSandbox) = await cli.stop(name: "no-such-sandbox") else {
            Issue.record("expected .unknownSandbox")
            return
        }
        #expect(harness.loggedArgv().filter { $0.first == "stop" }.isEmpty)
    }

    @Test("remove spawns exactly sbx rm --force <name>")
    func removeSpawnsExactArgv() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .success = await cli.remove(name: "test-sandbox-2") else {
            Issue.record("expected success")
            return
        }
        #expect(harness.loggedArgv().filter { $0.first == "rm" } == [["rm", "--force", "test-sandbox-2"]])
    }

    @Test("runExisting builds the re-attach argv (leading sbx token included) without spawning anything")
    func runExistingBuildsArgv() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .success(let argv) = await cli.runExisting(name: "test-sandbox-1", agentArgs: ["--model", "opusplan"]) else {
            Issue.record("expected success")
            return
        }
        #expect(argv == ["sbx", "run", "--name", "test-sandbox-1", "--", "--model", "opusplan"])
        #expect(harness.loggedArgv().filter { $0.first == "run" }.isEmpty) // never itself spawns `sbx run`
    }

    @Test("runExisting omits the -- separator when no args are given")
    func runExistingOmitsSeparator() async throws {
        let cli = makeCLI(try ShimHarness())
        guard case .success(let argv) = await cli.runExisting(name: "test-sandbox-2", agentArgs: []) else {
            Issue.record("expected success")
            return
        }
        #expect(argv == ["sbx", "run", "--name", "test-sandbox-2"])
    }

    @Test("addPolicy spawns the allow rule with --sandbox always present, then re-lists rules")
    func addPolicySpawnsAndRelists() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .success(let rules) = await cli.addPolicy(name: "test-sandbox-1", decision: .allow, resources: ["example.com"]) else {
            Issue.record("expected success")
            return
        }
        #expect(rules.count == 2)
        let mutating = harness.loggedArgv().filter { $0.first == "policy" && $0.dropFirst().first != "ls" }
        #expect(mutating == [["policy", "allow", "network", "--sandbox", "test-sandbox-1", "example.com"]])
    }

    @Test("removePolicy by rule id spawns exactly the rm invocation")
    func removePolicyByIdSpawns() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .success = await cli.removePolicy(name: "test-sandbox-1", ruleId: "removable-rule-id", resource: nil) else {
            Issue.record("expected success")
            return
        }
        let mutating = harness.loggedArgv().filter { $0.first == "policy" && $0.dropFirst().first == "rm" }
        #expect(mutating == [["policy", "rm", "network", "--sandbox", "test-sandbox-1", "--id", "removable-rule-id"]])
    }

    @Test("removePolicy refuses a non-removable (global) rule id without spawning a removal")
    func removePolicyRefusesGlobalRule() async throws {
        let harness = try ShimHarness()
        let cli = makeCLI(harness)
        guard case .failure(.ruleNotRemovable) = await cli.removePolicy(name: "test-sandbox-1", ruleId: "default-ai-services", resource: nil) else {
            Issue.record("expected .ruleNotRemovable")
            return
        }
        #expect(harness.loggedArgv().filter { $0.first == "policy" && $0.dropFirst().first == "rm" }.isEmpty)
    }

    @Test("listTemplates parses the shim's canned template ls table")
    func listTemplatesParses() async throws {
        let cli = makeCLI(try ShimHarness())
        #expect(await cli.listTemplates() == ["claude-sbx-dotnet10:v2", "claude-sbx-python:v1"])
    }

    @Test("listTemplates returns [] without throwing when sbx can't be located")
    func listTemplatesEmptyWhenToolMissing() async throws {
        let locator = ToolLocator(
            commandRunner: ProcessRunner(), environment: [:], configuredPath: nil,
            fixedProbePaths: [], fileExists: { _ in false }
        )
        let cli = SbxCLI(commandRunner: ProcessRunner(), toolLocator: locator)
        #expect(await cli.listTemplates() == [])
    }
}
```

- [ ] **Step 2: Run to verify failure** — `./Scripts/test.sh --filter SbxCLITests`
  Expected: FAIL — `SbxCLI`/`SbxCLIFailure` don't exist yet.

- [ ] **Step 3: Implement** `src/macos/Sources/SbxServices/SbxCLI.swift`:

```swift
// Ports src/electron/lib/sandboxes.mjs's listSandboxes/listNetworkRules,
// lib/templates.mjs's listTemplates, and server.mjs's requireKnownSandbox +
// the apiSandbox* route handlers' orchestration (argv build -> spawn ->
// parse), using SbxKit's already-ported argv builders and parsers. Never
// throws — every method reports failure through its return type, mirroring
// the JS `{ ok, error }` contract.
import Foundation
import SbxKit

public enum SbxCLIFailure: Error, Sendable, Equatable {
    /// `ToolLocator` couldn't find `sbx` at all.
    case toolNotFound
    /// The underlying `sbx` invocation itself failed (non-zero exit, spawn
    /// error, or unparseable output) — parity with server.mjs's 502.
    case infrastructure(String)
    /// `name` isn't in a fresh `sbx ls --json` — parity with server.mjs's 400
    /// for an unknown sandbox. Never cached: every mutating call re-checks.
    case unknownSandbox(String)
    /// The rule id exists but isn't sandbox-scoped-and-editable — refused
    /// before spawning `policy rm`, never after.
    case ruleNotRemovable(String)
    /// An argv-builder validation error from SbxKit (bad decision, no
    /// resources, too many agent-arg tokens, ...).
    case invalid(SbxKitError)
    /// The mutating command itself exited non-zero.
    case commandFailed(String)
}

public actor SbxCLI {
    private let commandRunner: CommandRunning
    private let toolLocator: ToolLocator
    private let timeout: Duration

    public init(commandRunner: CommandRunning, toolLocator: ToolLocator, timeout: Duration = .seconds(10)) {
        self.commandRunner = commandRunner
        self.toolLocator = toolLocator
        self.timeout = timeout
    }

    /// Spawns `argvWithSbxPrefix` (as built by SbxKit — element 0 is always
    /// the literal "sbx") against the resolved absolute `sbx` path. Drops
    /// that leading element before handing arguments to `CommandRunning`,
    /// which takes `executable:` separately — see this plan's Global
    /// Constraints on never passing "sbx" as arguments[0].
    private func invoke(_ argvWithSbxPrefix: [String]) async -> Result<CommandResult, SbxCLIFailure> {
        guard let sbxPath = await toolLocator.resolvedPath() else { return .failure(.toolNotFound) }
        let env = await toolLocator.childEnvironment()
        let result = await commandRunner.run(
            executable: sbxPath, arguments: Array(argvWithSbxPrefix.dropFirst()),
            stdin: nil, environment: env, timeout: timeout, maxOutputBytes: 1_000_000
        )
        return .success(result)
    }

    public func listSandboxes() async -> Result<[Sandbox], SbxCLIFailure> {
        switch await invoke(["sbx", "ls", "--json"]) {
        case .failure(let failure): return .failure(failure)
        case .success(let result):
            guard result.ok else {
                return .failure(.infrastructure(result.stderr.isEmpty ? "sbx ls failed." : result.stderr))
            }
            do { return .success(try parseSandboxLs(result.stdout)) }
            catch { return .failure(.infrastructure("Could not parse sbx ls output: \(error)")) }
        }
    }

    public func listTemplates() async -> [String] {
        guard let sbxPath = await toolLocator.resolvedPath() else { return [] }
        let env = await toolLocator.childEnvironment()
        let result = await commandRunner.run(
            executable: sbxPath, arguments: ["template", "ls"],
            stdin: nil, environment: env, timeout: .seconds(5), maxOutputBytes: 1_000_000
        )
        guard result.ok else { return [] }
        return parseTemplateLs(result.stdout)
    }

    /// Re-lists sandboxes fresh (never cached) and checks membership.
    /// `sbx policy ls <bogus-name> --json` exits 0 and returns the *global*
    /// rules, so every mutating/read call on a name must go through this
    /// first — see src/electron/CLAUDE.md's security-model section.
    private func requireKnownSandbox(_ name: String) async -> Result<Void, SbxCLIFailure> {
        switch await listSandboxes() {
        case .failure(let failure): return .failure(failure)
        case .success(let sandboxes):
            guard sandboxes.contains(where: { $0.name == name }) else { return .failure(.unknownSandbox(name)) }
            return .success(())
        }
    }

    public func listNetworkRules(name: String) async -> Result<[PolicyRule], SbxCLIFailure> {
        if case .failure(let failure) = await requireKnownSandbox(name) { return .failure(failure) }
        switch await invoke(["sbx", "policy", "ls", name, "--json"]) {
        case .failure(let failure): return .failure(failure)
        case .success(let result):
            guard result.ok else {
                return .failure(.infrastructure(result.stderr.isEmpty ? "sbx policy ls failed." : result.stderr))
            }
            do { return .success(try parseNetworkRules(stdout: result.stdout, sandboxName: name)) }
            catch { return .failure(.infrastructure("Could not parse sbx policy ls output: \(error)")) }
        }
    }

    public func stop(name: String) async -> Result<Void, SbxCLIFailure> {
        if case .failure(let failure) = await requireKnownSandbox(name) { return .failure(failure) }
        let args: [String]
        do { args = try buildStopArgs(name) } catch { return .failure(.invalid(error)) }
        switch await invoke(args) {
        case .failure(let failure): return .failure(failure)
        case .success(let result): return result.ok ? .success(()) : .failure(.commandFailed(result.stderr))
        }
    }

    public func remove(name: String) async -> Result<Void, SbxCLIFailure> {
        if case .failure(let failure) = await requireKnownSandbox(name) { return .failure(failure) }
        let args: [String]
        do { args = try buildRemoveArgs(name) } catch { return .failure(.invalid(error)) }
        switch await invoke(args) {
        case .failure(let failure): return .failure(failure)
        case .success(let result): return result.ok ? .success(()) : .failure(.commandFailed(result.stderr))
        }
    }

    /// Builds the re-attach argv only — does NOT spawn `sbx run` itself.
    /// That command opens an interactive attached session, so the caller
    /// hands this argv to `TerminalLauncher`, exactly like
    /// server.mjs's apiSandboxRun calling `launcher(args)` rather than `runSbx`.
    public func runExisting(name: String, agentArgs: [String]) async -> Result<[String], SbxCLIFailure> {
        if case .failure(let failure) = await requireKnownSandbox(name) { return .failure(failure) }
        do { return .success(try buildRunExistingArgs(name: name, agentArgs: agentArgs)) }
        catch { return .failure(.invalid(error)) }
    }

    public func addPolicy(name: String, decision: Decision, resources: [String]) async -> Result<[PolicyRule], SbxCLIFailure> {
        if case .failure(let failure) = await requireKnownSandbox(name) { return .failure(failure) }
        let args: [String]
        do { args = try buildPolicyAddArgs(name: name, decision: decision, resources: resources) }
        catch { return .failure(.invalid(error)) }
        switch await invoke(args) {
        case .failure(let failure): return .failure(failure)
        case .success(let result):
            guard result.ok else { return .failure(.commandFailed(result.stderr)) }
            return await listNetworkRules(name: name)
        }
    }

    /// Re-validates the target rule against a fresh policy list before
    /// spawning the removal — refuses anything not sandbox-scoped-and-
    /// editable, so a stale or forged rule id can't reach a global rule.
    public func removePolicy(name: String, ruleId: String?, resource: String?) async -> Result<Void, SbxCLIFailure> {
        if let ruleId, !ruleId.isEmpty {
            switch await listNetworkRules(name: name) {
            case .failure(let failure): return .failure(failure)
            case .success(let rules):
                guard let target = rules.first(where: { $0.id == ruleId }), target.removable else {
                    return .failure(.ruleNotRemovable(ruleId))
                }
            }
        } else {
            if case .failure(let failure) = await requireKnownSandbox(name) { return .failure(failure) }
        }
        let args: [String]
        do { args = try buildPolicyRemoveArgs(name: name, ruleId: ruleId, resource: resource) }
        catch { return .failure(.invalid(error)) }
        switch await invoke(args) {
        case .failure(let failure): return .failure(failure)
        case .success(let result): return result.ok ? .success(()) : .failure(.commandFailed(result.stderr))
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — `./Scripts/test.sh --filter SbxCLITests`
  Expected: all 13 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/SbxServices/SbxCLI.swift src/macos/Tests/SbxServicesTests/SbxCLITests.swift
git commit -m "macos: add SbxServices/SbxCLI"
```

---

### Task 5: TerminalLauncher

**Files:**
- Create: `src/macos/Sources/SbxServices/TerminalLauncher.swift`
- Test: `src/macos/Tests/SbxServicesTests/TerminalLauncherTests.swift`

**Interfaces:**
- Consumes: `CommandRunning` (Task 2), `formatCommand` (`SbxKit`, already ported).
- Produces:
  ```swift
  public struct LaunchResult: Sendable, Equatable { public var ok: Bool; public var method: String?; public var error: String? }
  public protocol TerminalLaunching: Sendable { func launch(args: [String]) async -> LaunchResult }
  public struct TerminalLauncher: TerminalLaunching { public init(commandRunner: CommandRunning) }
  ```
  Phase 4/6 models depend on `TerminalLaunching` as their injection seam.

- [ ] **Step 1: Write the failing tests** — `src/macos/Tests/SbxServicesTests/TerminalLauncherTests.swift`:

```swift
import Testing
import Foundation
@testable import SbxServices
import SbxKit

private actor RecordingRunner: CommandRunning {
    private(set) var calls: [(executable: String, arguments: [String])] = []
    private let scripted: [String: CommandResult] // keyed by executable
    init(scripted: [String: CommandResult]) { self.scripted = scripted }
    func run(executable: String, arguments: [String], stdin: Data?, environment: [String: String], timeout: Duration, maxOutputBytes: Int) async -> CommandResult {
        calls.append((executable, arguments))
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
}
```

- [ ] **Step 2: Run to verify failure** — `./Scripts/test.sh --filter TerminalLauncherTests`
  Expected: FAIL — `TerminalLauncher` doesn't exist yet.

- [ ] **Step 3: Implement** `src/macos/Sources/SbxServices/TerminalLauncher.swift`:

```swift
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
}

public protocol TerminalLaunching: Sendable {
    func launch(args: [String]) async -> LaunchResult
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

    /// `args` still carries its leading "sbx" element (see this plan's Global
    /// Constraints) — the script's own interactive shell resolves `sbx` via
    /// PATH, so no absolute-path resolution happens here.
    func writeRunScript(args: [String]) throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("sbx-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let scriptPath = (dir as NSString).appendingPathComponent("run.command")
        let content = "#!/bin/sh\nexec \(formatCommand(args))\n"
        FileManager.default.createFile(atPath: scriptPath, contents: Data(content.utf8), attributes: [.posixPermissions: 0o700])
        return scriptPath
    }

    public func launch(args: [String]) async -> LaunchResult {
        sweepStaleTempDirs()

        let scriptPath: String
        do { scriptPath = try writeRunScript(args: args) }
        catch { return LaunchResult(ok: false, method: nil, error: "\(error)") }

        let viaAppleScript = await commandRunner.run(
            executable: "/usr/bin/osascript", arguments: ["-e", Self.appleScript(forScriptPath: scriptPath)]
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
```

- [ ] **Step 4: Run to verify pass** — `./Scripts/test.sh --filter TerminalLauncherTests`
  Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/SbxServices/TerminalLauncher.swift src/macos/Tests/SbxServicesTests/TerminalLauncherTests.swift
git commit -m "macos: add SbxServices/TerminalLauncher"
```

---

### Task 6: SystemServices

**Files:**
- Create: `src/macos/Sources/SbxServices/SystemServices.swift`
- Test: `src/macos/Tests/SbxServicesTests/SystemServicesTests.swift`

**Interfaces:**
- Produces: `enum SystemServices { static func copyToClipboard(_ text: String) -> Bool; static func reveal(_ path: String) -> Bool }`

- [ ] **Step 1: Write the failing test** (only `copyToClipboard` is asserted on — `reveal` opens a real Finder window and has no observable return value beyond `Bool`; it's verified manually in this plan's Verification section, same as Phase 0 treated AppleEvent/display checks):

```swift
import Testing
import AppKit
@testable import SbxServices

@Suite("SystemServices")
struct SystemServicesTests {
    @Test("copyToClipboard round-trips through NSPasteboard.general")
    func copyRoundTrips() {
        let marker = "sbx-helper-test-\(UUID().uuidString)"
        #expect(SystemServices.copyToClipboard(marker) == true)
        #expect(NSPasteboard.general.string(forType: .string) == marker)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `./Scripts/test.sh --filter SystemServicesTests`
  Expected: FAIL — `SystemServices` doesn't exist yet.

- [ ] **Step 3: Implement** `src/macos/Sources/SbxServices/SystemServices.swift`:

```swift
// Native replacements for the two remaining Electron shell-outs:
// `pbcopy` -> NSPasteboard, `open <dir>` -> NSWorkspace. Ports
// src/electron/lib/terminal.mjs's copyToClipboard/revealInFinder.
import AppKit

public enum SystemServices {
    public static func copyToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// Opens `path` as its own Finder window — the same behavior as the JS's
    /// `open <dirPath>`, not a reveal-and-select within the parent.
    public static func reveal(_ path: String) -> Bool {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
```

- [ ] **Step 4: Run to verify pass** — `./Scripts/test.sh --filter SystemServicesTests`
  Expected: 1 test PASSes.

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/SbxServices/SystemServices.swift src/macos/Tests/SbxServicesTests/SystemServicesTests.swift
git commit -m "macos: add SbxServices/SystemServices"
```

---

### Task 7: ConfigStore

**Files:**
- Create: `src/macos/Sources/SbxServices/ConfigStore.swift`
- Test: `src/macos/Tests/SbxServicesTests/ConfigStoreTests.swift`

**Interfaces:**
- Consumes (from `SbxKit`, already ported): `AppConfig`, `loadConfig(_:)`, `saveConfig(_:_:)`.
- Produces:
  ```swift
  public actor ConfigStore {
      public init(path: String, debounceInterval: Duration = .milliseconds(300))
      public var loadError: String? { get }
      public var droppedPresets: Int { get }
      public func current() -> AppConfig
      public func update(_ transform: (inout AppConfig) -> Void)
      public func flush() async
  }
  ```
  Phase 3+'s `AppModel`/`AppDelegate` depend on `update`/`flush`.

- [ ] **Step 1: Write the failing tests** — `src/macos/Tests/SbxServicesTests/ConfigStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import SbxServices
import SbxKit

@Suite("ConfigStore")
struct ConfigStoreTests {
    func tempConfigPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sbx-helper-config-test-\(UUID().uuidString).json").path
    }

    @Test("creates and loads defaults when the file doesn't exist yet")
    func createsDefaultsWhenMissing() async {
        let path = tempConfigPath()
        let store = ConfigStore(path: path)
        let config = await store.current()
        #expect(config.agent == "claude")
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("update() is reflected by current() immediately, before any disk write")
    func updateIsImmediatelyVisible() async {
        let store = ConfigStore(path: tempConfigPath())
        await store.update { $0.defaultTemplate = "changed:v1" }
        let config = await store.current()
        #expect(config.defaultTemplate == "changed:v1")
    }

    @Test("rapid updates are debounced into a single disk write")
    func debouncesRapidUpdates() async throws {
        let path = tempConfigPath()
        let store = ConfigStore(path: path, debounceInterval: .milliseconds(50))
        await store.update { $0.agent = "one" }
        await store.update { $0.agent = "two" }
        await store.update { $0.agent = "three" }
        try await Task.sleep(for: .milliseconds(200))
        let onDisk = loadConfig(path).config
        #expect(onDisk.agent == "three")
    }

    @Test("flush() writes immediately without waiting for the debounce interval")
    func flushWritesImmediately() async {
        let path = tempConfigPath()
        let store = ConfigStore(path: path, debounceInterval: .seconds(30))
        await store.update { $0.agent = "flushed" }
        await store.flush()
        let onDisk = loadConfig(path).config
        #expect(onDisk.agent == "flushed")
    }

    @Test("surfaces loadError and droppedPresets from a malformed existing file")
    func surfacesLoadDiagnostics() async throws {
        let path = tempConfigPath()
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        let store = ConfigStore(path: path)
        let error = await store.loadError
        #expect(error != nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `./Scripts/test.sh --filter ConfigStoreTests`
  Expected: FAIL — `ConfigStore` doesn't exist yet.

- [ ] **Step 3: Implement** `src/macos/Sources/SbxServices/ConfigStore.swift`:

```swift
// Wraps SbxKit's already-ported loadConfig/saveConfig with an in-memory
// copy plus debounced disk writes, so a rapid sequence of UI-driven edits
// (e.g. retyping an agent-args tail) doesn't hit disk on every keystroke.
import Foundation
import SbxKit

public actor ConfigStore {
    private let path: String
    private var config: AppConfig
    public let loadError: String?
    public let droppedPresets: Int
    private let debounceInterval: Duration
    private var pendingSaveTask: Task<Void, Never>?

    public init(path: String, debounceInterval: Duration = .milliseconds(300)) {
        self.path = path
        self.debounceInterval = debounceInterval
        let loaded = loadConfig(path)
        self.config = loaded.config
        self.loadError = loaded.error
        self.droppedPresets = loaded.droppedPresets
    }

    public func current() -> AppConfig { config }

    /// Applies `transform` to the in-memory config immediately (visible to
    /// the very next `current()` call) and schedules a debounced disk write.
    public func update(_ transform: (inout AppConfig) -> Void) {
        transform(&config)
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        let path = self.path
        let snapshot = config
        let interval = debounceInterval
        pendingSaveTask = Task {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            saveConfig(path, snapshot)
        }
    }

    /// Forces an immediate write of whatever is currently in memory,
    /// bypassing the debounce — for AppDelegate's terminate-time flush.
    public func flush() async {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        saveConfig(path, config)
    }
}
```

- [ ] **Step 4: Run to verify pass** — `./Scripts/test.sh --filter ConfigStoreTests`
  Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/SbxServices/ConfigStore.swift src/macos/Tests/SbxServicesTests/ConfigStoreTests.swift
git commit -m "macos: add SbxServices/ConfigStore"
```

---

### Task 8: Wire the Phase 2 milestone probe into SbxHelperApp, retire the Phase 0 spike

**Files:**
- Delete: `src/macos/Sources/SbxHelperApp/PhaseZeroProbes.swift`
- Modify: `src/macos/Sources/SbxHelperApp/SbxHelperApp.swift`
- Create: `src/macos/Sources/SbxHelperApp/SbxServicesProbe.swift`

**Interfaces:**
- Consumes: `ToolLocator`, `ProcessRunner`, `SbxCLI` (Tasks 2-4).
- Produces: nothing later tasks depend on — this entire file is throwaway, deleted when Phase 3 lands the real Builder UI (same lifecycle as the Phase 0 probes it replaces).

- [ ] **Step 1: Delete the superseded Phase 0 spike**

```bash
git rm src/macos/Sources/SbxHelperApp/PhaseZeroProbes.swift
```

- [ ] **Step 2: Create** `src/macos/Sources/SbxHelperApp/SbxServicesProbe.swift`:

```swift
// Throwaway Phase 2 milestone probe — proves the whole SbxServices chain
// (ToolLocator -> SbxCLI -> real `sbx` on this machine) works end-to-end
// when run via `swift run SbxHelperApp` from a terminal (which, unlike a
// packaged .app, inherits the launching shell's PATH). Prints the parsed
// `sbx ls` result to stdout for manual comparison against the real CLI.
// Delete this file once Phase 3 lands the real Builder UI.
import SwiftUI
import SbxKit
import SbxServices

struct SbxServicesProbeView: View {
    @State private var summary = "not run yet"

    var body: some View {
        VStack(spacing: 16) {
            Text("Phase 2 milestone probe")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(32)
        .frame(minWidth: 460, minHeight: 260)
        .task {
            let locator = ToolLocator(
                commandRunner: ProcessRunner(),
                environment: ProcessInfo.processInfo.environment,
                configuredPath: nil
            )
            let cli = SbxCLI(commandRunner: ProcessRunner(), toolLocator: locator)
            let result = await cli.listSandboxes()
            let text: String
            switch result {
            case .success(let sandboxes):
                text = sandboxes.isEmpty
                    ? "sbx ls --json: 0 sandboxes"
                    : sandboxes.map { "\($0.name)\t\($0.agent)\t\($0.status)" }.joined(separator: "\n")
            case .failure(let failure):
                text = "FAILED: \(failure)"
            }
            print("=== Phase 2 milestone: parsed sbx ls ===\n\(text)\n=========================================")
            summary = text
        }
    }
}
```

- [ ] **Step 3: Modify** `src/macos/Sources/SbxHelperApp/SbxHelperApp.swift`:

```swift
import SwiftUI
import SbxKit

@main
struct SbxHelperApp: App {
    var body: some Scene {
        WindowGroup {
            SbxServicesProbeView()
        }
        .windowResizability(.contentSize)
    }
}
```

- [ ] **Step 4: Build** — `./Scripts/test.sh` isn't relevant here (no test changes); instead: `swift build -c release` (or `run-filtered.sh swift build -c release` per this session's own run-filtered rule) must succeed with the deleted file gone and the new one added.

- [ ] **Step 5: Commit**

```bash
git add -A src/macos/Sources/SbxHelperApp
git commit -m "macos: retire Phase 0 spike, wire Phase 2 milestone probe"
```

---

### Task 9: Update PLAN.md's Status section

**Files:**
- Modify: `src/macos/PLAN.md` (the "Status" section at the top, lines 1-28)

- [ ] **Step 1:** Following the exact style of the existing Phase 0/Phase 1 status entries, append a "Phase 2 (`SbxServices`) is complete" paragraph: number of `SbxServicesTests` passing, confirmation that `swift build -c release` and `./Scripts/package_app.sh`/`compile_and_run.sh` still succeed, and any real finding surfaced during implementation (e.g. if the timeout test needed a longer margin than planned, or if `NSWorkspace.shared.open` behaved differently than `selectFile` in a way worth flagging for Phase 8's Finder-reveal manual check). Update the "Phase 2 is next" line to "Phase 3 (App shell) is next."

- [ ] **Step 2: Commit**

```bash
git add src/macos/PLAN.md
git commit -m "macos: update PLAN.md status for completed Phase 2"
```

---

## Verification (run after every task, and again at the end)

```console
$ cd src/macos
$ swift build -c release              # or: run-filtered.sh swift build -c release
$ ./Scripts/test.sh                    # NOT plain `swift test`
$ SIGNING_MODE=adhoc ./Scripts/package_app.sh release
```

**Manual verification of the real milestone** (per this plan's earlier decision: automated tests only prove parity against the shim; the real-CLI check is a human step, same as Phase 0's own checklist):

1. `swift run SbxHelperApp` from a terminal with a normal shell `PATH` (so `ToolLocator`'s fixed-path/shell-probe tiers get exercised against the real `/opt/homebrew/bin/sbx` v0.39.0).
2. Confirm the window shows a real sandbox list (or "0 sandboxes" if none are running) and that the same text is printed to stdout.
3. Compare against `sbx ls --json` run directly in the same terminal — names/agent/status must match exactly.
4. If any sandboxes exist, spot-check one field manually (e.g. a port mapping) against the raw `sbx ls --json` output to catch a parsing regression the canned shim data wouldn't reveal.

---

## Self-Review Notes

- **Spec coverage:** every file PLAN.md lists under "SbxServices" (`ProcessRunner`, `ToolLocator`, `SbxCLI`, `TerminalLauncher`, `SystemServices`, `ConfigStore`) has a task; the three protocol seams PLAN.md calls for (`CommandRunning`, `SbxInvoking`→realized as `SbxCLI`'s own `Result`-based methods rather than a separate protocol since Phase 2 has exactly one implementation and no consumer yet to justify one — YAGNI, revisit in Phase 3+ if a model needs to fake it, `TerminalLaunching`) are all present. The Phase 0 spike retirement and the milestone are both covered (Task 8).
- **Parity traps called out explicitly:** the "sbx" leading-token drop (Global Constraints + called out again in `SbxCLI.invoke`'s doc comment), `requireKnownSandbox` re-checked every call, `removePolicy`'s re-validation before spawning, `runExisting` never itself spawning `sbx run`, `reveal` matching `open <dir>` semantics rather than `selectFile`, and the `exec sleep`-after-trap detail in the shim script (needed so the SIGTERM-ignoring test doesn't leave orphan processes).
- **Not duplicated:** `SbxInvoking` protocol dropped per YAGNI note above — `SbxCLI` is a concrete `actor`; if Phase 3+ needs to fake it for a view-model test, add a protocol then, against a real consumer's actual needs.
