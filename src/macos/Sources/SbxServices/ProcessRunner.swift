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

/// Decodes captured process output leniently — invalid UTF-8 (e.g. a
/// multi-byte sequence split by the output cap or an arbitrary pipe-chunk
/// boundary) is replaced with U+FFFD rather than discarding the entire
/// buffer, which `String(data:encoding:.utf8) ?? ""` would do.
func decodeCapturedOutput(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
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

/// Coordinates the three independent completion signals a spawned process
/// delivers — stdout EOF, stderr EOF, and process termination — which race
/// each other on separate dispatch queues. `terminationHandler` firing does
/// NOT imply the final `readabilityHandler` callback for a pipe has been
/// delivered yet; resolving as soon as termination fires (without waiting
/// for both EOFs too) can truncate a fast process's stdout. `readyToResolve`
/// returns `true` exactly once, to whichever of the three callbacks turns
/// out to be the last one — that's the only one allowed to build and
/// deliver the final result. The timeout path settles independently via
/// `trySettleForTimeout`, guarding against a subsequent late callback from
/// double-resolving.
private final class Coordination: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false
    private var exitStatus: Int32 = 0
    private var stdoutDone = false
    private var stderrDone = false
    private var isSettled = false

    func markTerminated(status: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        terminated = true
        exitStatus = status
        return readyToResolveLocked()
    }

    func markStdoutDone() -> Bool {
        lock.lock(); defer { lock.unlock() }
        stdoutDone = true
        return readyToResolveLocked()
    }

    func markStderrDone() -> Bool {
        lock.lock(); defer { lock.unlock() }
        stderrDone = true
        return readyToResolveLocked()
    }

    private func readyToResolveLocked() -> Bool {
        guard terminated, stdoutDone, stderrDone, !isSettled else { return false }
        isSettled = true
        return true
    }

    func trySettleForTimeout() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isSettled else { return false }
        isSettled = true
        return true
    }

    var currentExitStatus: Int32 {
        lock.lock(); defer { lock.unlock() }
        return exitStatus
    }
}

/// Lets the three completion callbacks (declared before the timeout `Task`
/// exists) cancel it once any of them wins the race — otherwise it lingers,
/// asleep, for the rest of `timeout`'s duration after a fast completion.
private final class TimeoutTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func set(_ task: Task<Void, Never>) { lock.lock(); self.task = task; lock.unlock() }
    func cancel() { lock.lock(); task?.cancel(); lock.unlock() }
}

public actor ProcessRunner: CommandRunning {
    public init() {
        // Writing to a pipe whose reader has already gone away raises
        // SIGPIPE, which by default TERMINATES THE PROCESS OUTRIGHT before
        // any Swift `catch` (or even an ObjC `@try`) ever runs — no API
        // choice on the write call itself can catch a process-level signal.
        // Every ProcessRunner needs a broken-pipe write to fail as a normal
        // EPIPE error instead. Signal disposition is process-global, so
        // setting this from multiple instances is harmless and idempotent.
        signal(SIGPIPE, SIG_IGN)
    }

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

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(ok: false, exitCode: nil, stdout: "", stderr: "\(error.localizedDescription)")
        }

        if let stdin, let stdinPipe {
            // Off the actor, via the throwing `write(contentsOf:)` rather
            // than the legacy `write(_:)`: a child that exits without
            // reading stdin closes the pipe's read end, and the legacy API
            // raises an uncaught (Swift-uncatchable) NSFileHandleOperation-
            // Exception on that EPIPE — a real crash, not a graceful
            // CommandResult failure. Detaching also keeps a stdin payload
            // larger than the pipe's kernel buffer from blocking this actor
            // for every other caller while the write drains.
            let handle = stdinPipe.fileHandleForWriting
            Task.detached {
                try? handle.write(contentsOf: stdin)
                try? handle.close()
            }
        }

        let pid = process.processIdentifier // captured first — see PLAN.md's ProcessRunner traps
        let coordination = Coordination()
        let timeoutTaskBox = TimeoutTaskBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
                @Sendable func buildResult(ok: Bool, exitCode: Int32?, timedOut: Bool) -> CommandResult {
                    CommandResult(
                        ok: ok, exitCode: exitCode,
                        stdout: decodeCapturedOutput(stdoutBuffer.snapshot),
                        stderr: decodeCapturedOutput(stderrBuffer.snapshot),
                        timedOut: timedOut
                    )
                }

                // Installed before `run()` returns control here, and always
                // fully drained regardless of `cap` — see OutputBuffer.append.
                // The empty-data callback is the EOF signal for that stream;
                // resolving only once ALL of {stdout EOF, stderr EOF,
                // termination} have fired avoids truncating a fast process's
                // output (terminationHandler racing ahead of the final
                // readability callback) — see Coordination's doc comment.
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        if coordination.markStdoutDone() {
                            timeoutTaskBox.cancel()
                            continuation.resume(returning: buildResult(
                                ok: coordination.currentExitStatus == 0,
                                exitCode: coordination.currentExitStatus, timedOut: false
                            ))
                        }
                    } else {
                        stdoutBuffer.append(chunk)
                    }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        if coordination.markStderrDone() {
                            timeoutTaskBox.cancel()
                            continuation.resume(returning: buildResult(
                                ok: coordination.currentExitStatus == 0,
                                exitCode: coordination.currentExitStatus, timedOut: false
                            ))
                        }
                    } else {
                        stderrBuffer.append(chunk)
                    }
                }

                let timeoutTask = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled, coordination.trySettleForTimeout() else { return }
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    kill(pid, SIGTERM)
                    let stderrText = decodeCapturedOutput(stderrBuffer.snapshot)
                    continuation.resume(returning: CommandResult(
                        ok: false, exitCode: nil,
                        stdout: decodeCapturedOutput(stdoutBuffer.snapshot),
                        stderr: stderrText.isEmpty ? "Timed out waiting for sbx." : stderrText,
                        timedOut: true
                    ))
                    // Give up waiting but still don't leave it running: escalate
                    // to SIGKILL if the child ignores SIGTERM. This detached
                    // task outliving the caller is intentional.
                    Task.detached {
                        try? await Task.sleep(for: .seconds(2))
                        // A liveness check first: if this pid has already
                        // exited (kill(pid, 0) fails with ESRCH), don't send
                        // SIGKILL — by now the pid could theoretically have
                        // been recycled by the kernel for an unrelated
                        // process, and there's no live handle to this
                        // specific child left to disambiguate against.
                        if kill(pid, 0) == 0 {
                            kill(pid, SIGKILL)
                        }
                    }
                }
                timeoutTaskBox.set(timeoutTask)

                process.terminationHandler = { proc in
                    let exitStatus = proc.terminationStatus
                    if coordination.markTerminated(status: exitStatus) {
                        timeoutTaskBox.cancel()
                        continuation.resume(returning: buildResult(ok: exitStatus == 0, exitCode: exitStatus, timedOut: false))
                    } else {
                        // Termination happened, but stdout/stderr haven't
                        // reached EOF yet — typically because a grandchild
                        // process (forked by the child before it died)
                        // inherited the pipe and is still holding its write
                        // end open, which would otherwise block EOF forever.
                        // Give any already in-flight data a brief grace
                        // period to arrive, then resolve with whatever's
                        // been captured rather than hang on an orphaned
                        // descendant we have no handle on.
                        Task {
                            try? await Task.sleep(for: .milliseconds(200))
                            guard coordination.trySettleForTimeout() else { return }
                            timeoutTaskBox.cancel()
                            stdoutPipe.fileHandleForReading.readabilityHandler = nil
                            stderrPipe.fileHandleForReading.readabilityHandler = nil
                            continuation.resume(returning: buildResult(ok: exitStatus == 0, exitCode: exitStatus, timedOut: false))
                        }
                    }
                }
            }
        } onCancel: {
            kill(pid, SIGTERM)
        }
    }
}
