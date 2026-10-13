// Covers SbxKit's SbxInvocation/SbxInvocationLog — the backing store for
// the Sandboxes tab's live "sbx commands" debug section. The log must stay
// bounded (a failed `sbx ls` on every refresh must not grow memory without
// limit) and must never lose the tail of a response to truncation in a way
// that hides the parse-relevant bytes.
import Testing
@testable import SbxKit

@Suite("SbxInvocationLog")
struct SbxInvocationLogTests {
    private func entry(id: UInt64 = 0, stdout: String = "[]", stderr: String = "") -> SbxInvocation {
        SbxInvocation(id: id, command: "sbx ls --json", ok: true, exitCode: 0, stdout: stdout, stderr: stderr)
    }

    @Test("appended entries are stored newest-last")
    func storesNewestLast() {
        var log = SbxInvocationLog()
        log.append(entry(id: 0))
        log.append(entry(id: 1))
        #expect(log.entries.map(\.id) == [0, 1])
    }

    @Test("the log drops the oldest entries past its cap")
    func dropsOldestPastCap() {
        var log = SbxInvocationLog()
        for i in 0 ..< (SbxInvocationLog.maxEntries + 5) {
            log.append(entry(id: UInt64(i)))
        }
        #expect(log.entries.count == SbxInvocationLog.maxEntries)
        #expect(log.entries.first?.id == 5)
        #expect(log.entries.last?.id == UInt64(SbxInvocationLog.maxEntries + 4))
    }

    @Test("output past the char cap is truncated with a marker")
    func truncatesLongOutput() {
        var log = SbxInvocationLog()
        let long = String(repeating: "x", count: SbxInvocationLog.maxOutputChars + 100)
        log.append(entry(stdout: long))
        let stored = log.entries[0].stdout
        #expect(stored.count < long.count)
        #expect(stored.hasSuffix("chars total)"))
        #expect(stored.hasPrefix(String(repeating: "x", count: SbxInvocationLog.maxOutputChars)))
    }

    @Test("short output passes through untouched")
    func shortOutputUntouched() {
        var log = SbxInvocationLog()
        log.append(entry(stdout: "[]", stderr: "oops"))
        #expect(log.entries[0].stdout == "[]")
        #expect(log.entries[0].stderr == "oops")
    }

    @Test("statusText reports the exit code, or that nothing spawned")
    func statusText() {
        #expect(entry().statusText == "exit 0")
        let failed = SbxInvocation(id: 1, command: "sbx stop x", ok: false, exitCode: 1, stdout: "", stderr: "boom")
        #expect(failed.statusText == "exit 1")
        let missing = SbxInvocation(id: 2, command: "sbx ls --json", ok: false, exitCode: nil, stdout: "", stderr: "sbx not found")
        #expect(missing.statusText == "not started")
    }
}
