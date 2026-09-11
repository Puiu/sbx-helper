// Every SbxKitError case's message must match its JS `throw new Error(...)`
// string byte-for-byte — these banners surface directly in the UI. See the
// sources in public/shared/command.mjs and public/shared/sandbox-commands.mjs.
import Testing
@testable import SbxKit

@Suite("SbxKitError message parity")
struct ErrorMessageParityTests {
    @Test(
        "case description matches the JS error string exactly",
        arguments: [
            (SbxKitError.noEditableWorkspace, "At least one editable workspace is required."),
            (SbxKitError.sandboxNameRequired, "A sandbox name is required."),
            (SbxKitError.invalidDecision, "decision must be \"allow\" or \"deny\"."),
            (SbxKitError.noResources, "At least one resource is required."),
            (SbxKitError.ruleIdOrResourceRequired, "Either ruleId or resource is required."),
            (SbxKitError.agentArgsNotAList, "Agent arguments must be a list."),
            (SbxKitError.tooManyAgentArgTokens(max: 32), "Too many agent-argument tokens (max 32)."),
            (SbxKitError.emptyAgentArgToken, "Agent-argument tokens must be non-empty strings."),
            (SbxKitError.agentArgTokenTooLong(max: 256), "An agent-argument token is too long (max 256 characters)."),
            (SbxKitError.agentArgControlCharacter, "Agent-argument tokens must not contain control characters."),
            (
                SbxKitError.overlappingSelection(detail: "/root/A/B is inside /root/A"),
                "Overlapping selection: /root/A/B is inside /root/A"
            ),
            (SbxKitError.notAbsolutePath, "Every workspace path must be an absolute path."),
            (SbxKitError.folderNotFound(path: "/root/gone"), "Folder not found: /root/gone"),
            (SbxKitError.presetNameRequired, "Preset name is required."),
            (
                SbxKitError.presetRequiresEditable,
                "Select at least one editable folder before saving."
            ),
            (SbxKitError.rootPathRequired, "rootPath is required."),
            (SbxKitError.pathNotFound(path: "/root/gone"), "Not found: /root/gone"),
            (SbxKitError.notADirectory(path: "/root/file"), "Not a directory: /root/file"),
            (SbxKitError.revealPathMustBeAbsolute, "path must be an absolute path."),
        ]
    )
    func messageMatchesJS(error: SbxKitError, expected: String) {
        #expect(error.errorDescription == expected)
    }
}
