import Testing
import Foundation
@testable import SbxServices

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("decodeCapturedOutput replaces invalid UTF-8 instead of discarding the whole buffer")
    func decodeCapturedOutputIsLossyNotDestructive() {
        // A capped or pipe-chunk-boundary truncation can land mid-character
        // — e.g. only the first byte (0xC3) of "é" (0xC3 0xA9). Strict
        // String(data:encoding:.utf8) fails on the WHOLE buffer for this,
        // not just the broken tail.
        var data = Data("safe prefix ".utf8)
        data.append(0xC3)
        let decoded = decodeCapturedOutput(data)
        #expect(decoded.hasPrefix("safe prefix "))
        #expect(!decoded.isEmpty)
    }

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
        // Matches JS's `append` semantics exactly (lib/sandboxes.mjs: growth
        // stops once `existing.length >= MAX_OUTPUT_BYTES`, without trimming
        // an already-in-flight chunk to fit exactly) — so the invariant under
        // test is "didn't buffer the full 500_000 bytes", not "capped exactly
        // at maxOutputBytes".
        #expect(result.stdout.utf8.count < 500_000)
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

    @Test("the SIGKILL escalation actually terminates a child that ignores SIGTERM")
    func sigkillEscalationActuallyKillsTheChild() async throws {
        let harness = try ShimHarness()
        let runner = ProcessRunner()
        var env = harness.environment
        env["SBX_SHIM_IGNORE_TERM"] = "1"
        env["SBX_SHIM_SLEEP_SECONDS"] = "30"
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("sbx-shim-pid-\(UUID().uuidString)").path
        env["SBX_SHIM_PID_FILE"] = pidFile

        _ = await runner.run(
            executable: harness.shimPath, arguments: ["stop", "wedged-sandbox-2"],
            stdin: nil, environment: env, timeout: .milliseconds(300), maxOutputBytes: 1_000_000
        )

        // Without this check, deleting ProcessRunner's `Task.detached { ...
        // kill(pid, SIGKILL) }` escalation entirely would leave the other
        // timeout test green (it only asserts the timeout path's own
        // result) while leaking a 30s `sleep` per run. Wait past the 2s
        // SIGTERM->SIGKILL delay, then confirm the pid is actually gone.
        try await Task.sleep(for: .milliseconds(2600))
        guard let pidString = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = pid_t(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            Issue.record("shim never wrote its pid to \(pidFile)")
            return
        }
        #expect(kill(pid, 0) == -1) // ESRCH: no such process — it's actually gone
    }

    @Test("writing stdin to a child that already closed its read end never crashes (EPIPE)")
    func stdinWriteSurvivesEpipe() async throws {
        let harness = try ShimHarness()
        let runner = ProcessRunner()
        var env = harness.environment
        env["SBX_SHIM_CLOSE_STDIN"] = "1"
        // Larger than the ~16-64KB kernel pipe buffer, so the write can't
        // just succeed by fitting entirely into kernel-buffered space before
        // the child (which never reads it) exits and closes its end.
        let payload = Data(repeating: 0x41, count: 200_000)
        let result = await runner.run(
            executable: harness.shimPath, arguments: ["stop", "epipe-test"],
            stdin: payload, environment: env, timeout: .seconds(5), maxOutputBytes: 1_000_000
        )
        // The point of this test is that it returns at all, rather than
        // crashing the process with an uncaught NSFileHandleOperationException.
        #expect(result.ok == true)
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

    @Test("a cancelled run settles even when the child ignores SIGTERM")
    func cancellationSettlesWhenChildIgnoresSigterm() async throws {
        let harness = try ShimHarness()
        let runner = ProcessRunner()
        var env = harness.environment
        env["SBX_SHIM_IGNORE_TERM"] = "1"
        env["SBX_SHIM_SLEEP_SECONDS"] = "30"
        let start = ContinuousClock.now
        let task = Task {
            await runner.run(
                executable: harness.shimPath, arguments: ["stop", "cancel-ignores-term"],
                stdin: nil, environment: env, timeout: .seconds(60), maxOutputBytes: 1_000_000
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        let elapsed = ContinuousClock.now - start
        #expect(result.ok == false)
        #expect(result.timedOut == false)
        #expect(elapsed < .seconds(10))
    }
}
