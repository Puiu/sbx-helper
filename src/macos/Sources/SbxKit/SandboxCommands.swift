// Ports src/electron/public/shared/sandbox-commands.mjs — argv assembly for
// the Sandboxes tab: run (re-attach), stop, rm, and per-sandbox network
// policy allow/deny/rm.

public enum Decision: String, Sendable, Equatable {
    case allow
    case deny
}

private func requireName(_ name: String) throws(SbxKitError) -> String {
    let trimmed = jsTrim(name)
    guard !trimmed.isEmpty else { throw .sandboxNameRequired }
    return trimmed
}

/// Builds `sbx run --name <name> [-- AGENT_ARGS...]` to re-attach to an
/// existing sandbox. The -- separator is omitted entirely when there are no
/// agent args, matching how a user would type the command by hand.
public func buildRunExistingArgs(name: String, agentArgs: [String]) throws(SbxKitError) -> [String] {
    let trimmedName = try requireName(name)
    if let invalidReason = validateAgentArgs(agentArgs) { throw invalidReason }
    var args = ["sbx", "run", "--name", trimmedName]
    if !agentArgs.isEmpty { args.append("--"); args.append(contentsOf: agentArgs) }
    return args
}

/// Builds `sbx stop <name>`.
public func buildStopArgs(_ name: String) throws(SbxKitError) -> [String] {
    ["sbx", "stop", try requireName(name)]
}

/// Builds `sbx rm --force <name>`. --force skips the CLI's interactive confirmation.
public func buildRemoveArgs(_ name: String) throws(SbxKitError) -> [String] {
    ["sbx", "rm", "--force", try requireName(name)]
}

/// Builds `sbx policy allow|deny network --sandbox <name> <resources>`.
/// Resources are joined into a single comma-separated argv token, as the
/// CLI expects (RESOURCES is one comma-separated list, not repeated flags).
public func buildPolicyAddArgs(name: String, decision: Decision, resources: [String]) throws(SbxKitError) -> [String] {
    let trimmedName = try requireName(name)
    guard !resources.isEmpty else { throw .noResources }
    return ["sbx", "policy", decision.rawValue, "network", "--sandbox", trimmedName, resources.joined(separator: ",")]
}

/// Builds `sbx policy rm network --sandbox <name> --id <ruleId>` or
/// `--resource <resource>`. Exactly one of ruleId/resource must be given.
///
/// JS guards on truthiness (`if (!ruleId && !resource) throw`, `if (ruleId)
/// ... else ...`), where an empty string is exactly as absent as
/// null/undefined — so an empty string here is treated as absent too,
/// not just `nil`.
public func buildPolicyRemoveArgs(name: String, ruleId: String?, resource: String?) throws(SbxKitError) -> [String] {
    let trimmedName = try requireName(name)
    let ruleId = (ruleId?.isEmpty == false) ? ruleId : nil
    let resource = (resource?.isEmpty == false) ? resource : nil
    guard ruleId != nil || resource != nil else { throw .ruleIdOrResourceRequired }
    var args = ["sbx", "policy", "rm", "network", "--sandbox", trimmedName]
    if let ruleId { args.append(contentsOf: ["--id", ruleId]) } else { args.append(contentsOf: ["--resource", resource!]) }
    return args
}
