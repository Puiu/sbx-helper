// Ports src/electron/public/shared/command.mjs — orderedWorkspaces,
// buildArgs, buildCommand.

/// The `sbx run` selection: mirrors the JS options bag passed to buildArgs.
public struct RunSelection: Sendable, Equatable {
    public var agent: String
    public var template: String
    public var name: String?
    public var clone: Bool
    public var editable: [String]
    public var readOnly: [String]
    public var primary: String?

    public init(
        agent: String, template: String, name: String?, clone: Bool,
        editable: [String], readOnly: [String], primary: String?
    ) {
        self.agent = agent
        self.template = template
        self.name = name
        self.clone = clone
        self.editable = editable
        self.readOnly = readOnly
        self.primary = primary
    }
}

/// Primary first, then the rest of the editable paths in a stable order.
public func orderedWorkspaces(primary: String, editable: [String]) -> [String] {
    let rest = editable.filter { $0 != primary }.sorted(by: JSOrder.precedes)
    return [primary] + rest
}

/// Builds the `sbx run` argv:
///   sbx run --template <tpl> [--name <n>] [--clone] <agent> <primary> [<other editable>…] [<ro>:ro …]
///
/// Throws `.noEditableWorkspace` if `editable` is empty — callers must guard
/// for that (there is nothing sensible to run without at least one editable
/// workspace). Also enforces `findAnyConflict` as a precondition — in the
/// Electron app this was `server.mjs`'s job, checked before `buildCommand`;
/// that server layer doesn't exist here, so a preset loaded from a
/// hand-edited config (which bypasses the UI's per-click
/// `findCoveringPath` check) must still be caught here.
public func buildArgs(_ selection: RunSelection) throws(SbxKitError) -> [String] {
    guard !selection.editable.isEmpty else { throw .noEditableWorkspace }
    if let conflict = findAnyConflict(selection.editable + selection.readOnly) {
        throw .overlappingSelection(detail: conflict)
    }
    let actualPrimary = resolvePrimary(selection.editable, explicit: selection.primary)!
    let ordered = orderedWorkspaces(primary: actualPrimary, editable: selection.editable)

    var args = ["sbx", "run", "--template", selection.template]
    let trimmedName = selection.name.map(jsTrim)
    if let trimmedName, !trimmedName.isEmpty {
        args.append(contentsOf: ["--name", trimmedName])
    }
    if selection.clone { args.append("--clone") }
    args.append(selection.agent)
    args.append(contentsOf: ordered)
    args.append(contentsOf: selection.readOnly.sorted(by: JSOrder.precedes).map { $0 + ":ro" })
    return args
}

/// Convenience wrapper returning both the argv and its display string.
public func buildCommand(_ selection: RunSelection) throws(SbxKitError) -> (args: [String], display: String) {
    let args = try buildArgs(selection)
    return (args, formatCommand(args))
}
