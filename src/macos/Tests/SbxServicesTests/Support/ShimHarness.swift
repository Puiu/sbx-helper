// Locates and drives Tests/SbxServicesTests/Fixtures/sbx-shim.sh via its
// source-relative path — NOT an SPM bundle resource. See
// Tests/SbxKitTests/Support/ParityCorpus.swift for why (Bundle.module is
// unreliable under bare CLT per the Phase 0 findings in PLAN.md).
import Foundation

struct ShimHarness {
    let shimPath: String
    let logPath: String
    var environment: [String: String]

    init() throws {
        // NOT a default parameter value: `#filePath` as a default argument
        // resolves at the CALL site, not here — it must be a literal used
        // directly in the body to always mean "this file", regardless of
        // which test file constructs a ShimHarness.
        let thisFile = #filePath
        let supportDir = (thisFile as NSString).deletingLastPathComponent
        let testsDir = (supportDir as NSString).deletingLastPathComponent
        shimPath = (testsDir as NSString).appendingPathComponent("Fixtures/sbx-shim.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimPath)

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sbx-shim-log-\(UUID().uuidString)")
        logPath = logURL.path
        FileManager.default.createFile(atPath: logPath, contents: Data())

        // Include a real PATH, not just SBX_SHIM_LOG: ToolLocator.
        // childEnvironment() prepends onto whatever base PATH it's given,
        // and the shim script itself needs /bin:/usr/bin on that PATH to
        // resolve its own internal `cat`/`sed`/`head`/`tr` calls — a real
        // launchd-launched app's inherited PATH already has those; a bare
        // ["SBX_SHIM_LOG": ...] dict does not.
        environment = [
            "SBX_SHIM_LOG": logPath,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
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
