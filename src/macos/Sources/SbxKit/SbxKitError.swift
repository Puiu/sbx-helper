// One case per JS `throw new Error(...)` site across command.mjs and
// sandbox-commands.mjs. `errorDescription` reproduces the JS message
// byte-for-byte — these strings surface directly as UI banners.
import Foundation

public enum SbxKitError: Error, Equatable, Sendable, LocalizedError {
    /// command.mjs buildArgs — "At least one editable workspace is required."
    case noEditableWorkspace
    /// sandbox-commands.mjs — every `name` guard: "A sandbox name is required."
    case sandboxNameRequired
    /// buildPolicyAddArgs — "decision must be \"allow\" or \"deny\"."
    case invalidDecision
    /// buildPolicyAddArgs — "At least one resource is required."
    case noResources
    /// buildPolicyRemoveArgs — "Either ruleId or resource is required."
    case ruleIdOrResourceRequired
    /// validateAgentArgs — "Agent arguments must be a list."
    case agentArgsNotAList
    /// validateAgentArgs — "Too many agent-argument tokens (max N)."
    case tooManyAgentArgTokens(max: Int)
    /// validateAgentArgs — "Agent-argument tokens must be non-empty strings."
    case emptyAgentArgToken
    /// validateAgentArgs — "An agent-argument token is too long (max N characters)."
    case agentArgTokenTooLong(max: Int)
    /// validateAgentArgs — "Agent-argument tokens must not contain control characters."
    case agentArgControlCharacter
    /// server.mjs's pre-buildCommand backstop, now enforced inside buildArgs
    /// itself (see PLAN.md) — "Overlapping selection: <findAnyConflict's detail>"
    case overlappingSelection(detail: String)
    /// server.mjs apiRun's per-path guard — "Every workspace path must be an absolute path."
    case notAbsolutePath
    /// server.mjs apiRun's per-path guard — "Folder not found: <path>"
    case folderNotFound(path: String)
    /// server.mjs apiPresets save — "Preset name is required."
    case presetNameRequired
    /// server.mjs apiPresets save — "Select at least one editable folder before saving."
    case presetRequiresEditable
    /// server.mjs apiScan — "rootPath is required."
    case rootPathRequired
    /// server.mjs apiScan — "Not found: <path>"
    case pathNotFound(path: String)
    /// server.mjs apiReveal — "path must be an absolute path."
    case revealPathMustBeAbsolute
    /// server.mjs apiReveal — "Not a directory: <path>" (apiScan shares it)
    case notADirectory(path: String)

    public var errorDescription: String? {
        switch self {
        case .noEditableWorkspace:
            "At least one editable workspace is required."
        case .sandboxNameRequired:
            "A sandbox name is required."
        case .invalidDecision:
            "decision must be \"allow\" or \"deny\"."
        case .noResources:
            "At least one resource is required."
        case .ruleIdOrResourceRequired:
            "Either ruleId or resource is required."
        case .agentArgsNotAList:
            "Agent arguments must be a list."
        case .tooManyAgentArgTokens(let max):
            "Too many agent-argument tokens (max \(max))."
        case .emptyAgentArgToken:
            "Agent-argument tokens must be non-empty strings."
        case .agentArgTokenTooLong(let max):
            "An agent-argument token is too long (max \(max) characters)."
        case .agentArgControlCharacter:
            "Agent-argument tokens must not contain control characters."
        case .overlappingSelection(let detail):
            "Overlapping selection: \(detail)"
        case .notAbsolutePath:
            "Every workspace path must be an absolute path."
        case .folderNotFound(let path):
            "Folder not found: \(path)"
        case .presetNameRequired:
            "Preset name is required."
        case .presetRequiresEditable:
            "Select at least one editable folder before saving."
        case .rootPathRequired:
            "rootPath is required."
        case .pathNotFound(let path):
            "Not found: \(path)"
        case .revealPathMustBeAbsolute:
            "path must be an absolute path."
        case .notADirectory(let path):
            "Not a directory: \(path)"
        }
    }
}
