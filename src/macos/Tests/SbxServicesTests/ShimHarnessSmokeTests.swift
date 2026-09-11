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
