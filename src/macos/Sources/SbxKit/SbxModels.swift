// Ports src/electron/lib/sandboxes.mjs — parseSandboxLs, parseNetworkRules —
// plus formatPort, which actually lives in
// src/electron/public/shared/sandbox-commands.mjs (lib/sandboxes.mjs only
// re-exports it); here it's Port.formatted.
import Foundation

/// One `sbx ls --json` published-port entry.
public struct Port: Sendable, Equatable, Codable {
    public var hostIP: String?
    public var hostPort: Int
    public var sandboxPort: Int
    public var protocolName: String

    private enum CodingKeys: String, CodingKey {
        case hostIP = "host_ip"
        case hostPort = "host_port"
        case sandboxPort = "sandbox_port"
        case protocolName = "protocol"
    }

    public init(hostIP: String? = nil, hostPort: Int, sandboxPort: Int, protocolName: String) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.sandboxPort = sandboxPort
        self.protocolName = protocolName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostIP = c.lenient(.hostIP, nil as String?)
        hostPort = c.lenient(.hostPort, 0)
        sandboxPort = c.lenient(.sandboxPort, 0)
        protocolName = c.lenient(.protocolName, "")
    }

    /// Formats the way `sbx ls`'s PORTS column reads.
    public var formatted: String {
        let arrow = "\(hostPort)->\(sandboxPort)/\(protocolName)"
        if let hostIP { return "\(hostIP):\(arrow)" }
        return arrow
    }
}

/// One entry from `sbx ls --json`.
public struct Sandbox: Sendable, Equatable, Identifiable, Decodable {
    public var name: String
    public var id: String
    public var agent: String
    public var status: String
    public var workspaces: [String]
    public var ports: [Port]

    private enum CodingKeys: String, CodingKey {
        case name, id, agent, status, workspaces, ports
    }

    public init(name: String, id: String, agent: String, status: String, workspaces: [String], ports: [Port]) {
        self.name = name
        self.id = id
        self.agent = agent
        self.status = status
        self.workspaces = workspaces
        self.ports = ports
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenient(.name, "")
        id = c.lenient(.id, "")
        agent = c.lenient(.agent, "")
        status = c.lenient(.status, "")
        workspaces = c.lenientArray(.workspaces, [])
        ports = c.lenientArray(.ports, [])
    }
}

/// Parses `sbx ls --json` stdout into a flat sandbox list. Throws on
/// malformed JSON; drops any array element that isn't a well-formed object
/// rather than failing the whole list.
public func parseSandboxLs(_ stdout: String) throws -> [Sandbox] {
    struct Envelope: Decodable { let sandboxes: [Failable<Sandbox>]? }
    let envelope = try JSONDecoder().decode(Envelope.self, from: Data(stdout.utf8))
    return (envelope.sandboxes ?? []).compactMap(\.value)
}

/// One raw `sbx policy ls <name> --json` rule, before the network-only
/// filter and the sandboxScoped/removable annotation are applied.
private struct RawPolicyRule: Decodable {
    let id: String
    let name: String
    let decision: String
    let resources: [String]
    let scope: String
    let origin: String
    let status: String
    let resourceType: String
    let editable: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, name, decision, resources, scope, origin, status, editable
        case resourceType = "resource_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, "")
        name = c.lenient(.name, "")
        decision = c.lenient(.decision, "")
        resources = c.lenientArray(.resources, [])
        scope = c.lenient(.scope, "")
        origin = c.lenient(.origin, "")
        status = c.lenient(.status, "")
        resourceType = c.lenient(.resourceType, "")
        // Fail closed: a rule missing `editable` entirely (or with a
        // wrong-typed value) is not editable — `nil` here, not `false`,
        // so the distinction survives into `removable`'s `== true` check.
        editable = try? c.decodeIfPresent(Bool.self, forKey: .editable)
    }
}

/// One `sbx policy ls <name> --json` network rule, annotated with whether
/// it's scoped to the sandbox and safe to offer removal for.
public struct PolicyRule: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var decision: String
    public var resources: [String]
    public var scope: String
    public var origin: String
    public var status: String
    public var sandboxScoped: Bool
    public var removable: Bool

    public init(id: String, name: String, decision: String, resources: [String], scope: String, origin: String, status: String, sandboxScoped: Bool, removable: Bool) {
        self.id = id
        self.name = name
        self.decision = decision
        self.resources = resources
        self.scope = scope
        self.origin = origin
        self.status = status
        self.sandboxScoped = sandboxScoped
        self.removable = removable
    }

    /// The scope badge text — ports app.js's `renderPolicies` scope label:
    /// the sandbox's own rules read "this sandbox", anything else is a kit
    /// rule ("kit") or a broader rule ("global").
    public var scopeLabel: String {
        if sandboxScoped { return "this sandbox" }
        return origin == "scoped" ? "kit" : "global"
    }
}

/// Parses `sbx policy ls <name> --json` stdout into network-only rules,
/// annotated with whether each rule is scoped to `sandboxName` and whether
/// it's safe to offer removal for (sandbox-scoped AND editable).
/// Sandbox-scoped rules sort first so the sandbox's own rules are what you
/// see — a stable partition, not a sort, so `sbx`'s own within-group
/// ordering survives (Swift's `sorted(by:)` is not a stable sort).
public func parseNetworkRules(stdout: String, sandboxName: String) throws -> [PolicyRule] {
    struct Envelope: Decodable { let rules: [Failable<RawPolicyRule>]? }
    let envelope = try JSONDecoder().decode(Envelope.self, from: Data(stdout.utf8))
    let raw = (envelope.rules ?? []).compactMap(\.value)
    let scopeTag = "sandbox:\(sandboxName)"

    let rules = raw
        .filter { $0.resourceType == "network" }
        .map { r -> PolicyRule in
            let sandboxScoped = r.scope == scopeTag
            return PolicyRule(
                id: r.id, name: r.name, decision: r.decision, resources: r.resources,
                scope: r.scope, origin: r.origin, status: r.status,
                sandboxScoped: sandboxScoped,
                // Fail closed twice: sandbox-scoped AND explicitly editable
                // AND carrying an id the removal lookup can actually match —
                // an id-less rule would otherwise render a × button whose
                // removal can never succeed.
                removable: sandboxScoped && r.editable == true && !r.id.isEmpty
            )
        }

    return rules.filter(\.sandboxScoped) + rules.filter { !$0.sandboxScoped }
}

/// The policy section's summary line — ports app.js's `renderPolicies`
/// summary. One deliberate one-word fix: the JS interpolates "1 rule
/// apply"; that reads as a bug in the UI, so the singular here is
/// "applies".
public func policySummary(_ rules: [PolicyRule]) -> String {
    let scopedCount = rules.filter(\.sandboxScoped).count
    let denyCount = rules.filter { $0.decision == "deny" }.count
    let noun = rules.count == 1 ? "1 rule applies" : "\(rules.count) rules apply"
    return "\(noun) · \(scopedCount) scoped to this sandbox · \(denyCount) deny"
}
