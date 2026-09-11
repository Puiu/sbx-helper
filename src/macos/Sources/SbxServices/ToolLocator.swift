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
        // Take the LAST non-empty line, not the whole trimmed output: a
        // login shell's .zshenv/.zprofile can print banner noise before the
        // real answer. Then gate through fileExists — `command -v` also
        // succeeds for a shell function or alias definition (multi-line,
        // and not a real file at all), which must not be cached as the
        // resolved path.
        let lines = probe.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let candidate = lines.last(where: { !$0.isEmpty }), fileExists(candidate) else { return nil }
        return candidate
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
