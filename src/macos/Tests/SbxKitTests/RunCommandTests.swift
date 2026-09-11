// Ports src/electron/test/command.test.mjs (buildCommand describe block) and
// exercises orderedWorkspaces directly.
import Testing
@testable import SbxKit

struct CommandCase: CustomTestStringConvertible {
    let selection: RunSelection
    let expectedDisplay: String
    var testDescription: String { expectedDisplay }
}

@Suite("buildCommand")
struct RunCommandTests {
    @Test(
        "produces the expected display string",
        arguments: [
            CommandCase(
                selection: RunSelection(
                    agent: "claude", template: "claude-sbx-dotnet10:v2", name: nil, clone: false,
                    editable: ["/path/to/NHO.0476.ConsentRegister.Web"],
                    readOnly: ["/path/to/NHO.AccessHub.Web"], primary: nil
                ),
                expectedDisplay: "sbx run --template claude-sbx-dotnet10:v2 claude "
                    + "/path/to/NHO.0476.ConsentRegister.Web /path/to/NHO.AccessHub.Web:ro"
            ),
            CommandCase(
                selection: RunSelection(
                    agent: "claude", template: "tpl:v1", name: "my-sandbox", clone: true,
                    editable: ["/root/A"], readOnly: [], primary: nil
                ),
                expectedDisplay: "sbx run --template tpl:v1 --name my-sandbox --clone claude /root/A"
            ),
        ]
    )
    func matchesExpectedDisplay(_ c: CommandCase) throws {
        let (_, display) = try buildCommand(c.selection)
        #expect(display == c.expectedDisplay)
    }

    @Test("supports multiple editable and multiple read-only folders, primary first")
    func multipleEditableAndReadOnly() throws {
        let (args, _) = try buildCommand(RunSelection(
            agent: "claude", template: "tpl", name: nil, clone: false,
            editable: ["/root/B", "/root/A"], readOnly: ["/root/D", "/root/C"], primary: "/root/A"
        ))
        #expect(args == [
            "sbx", "run", "--template", "tpl",
            "claude", "/root/A", "/root/B", "/root/C:ro", "/root/D:ro",
        ])
    }

    @Test("the :ro suffix stays inside the quotes for a spaced path")
    func roSuffixInsideQuotes() throws {
        let (_, display) = try buildCommand(RunSelection(
            agent: "claude", template: "tpl", name: nil, clone: false,
            editable: ["/root/A"], readOnly: ["/path/with space"], primary: nil
        ))
        #expect(display.contains("'/path/with space:ro'"))
    }

    @Test("an unpromoted, no-longer-editable primary falls back to the default")
    func unpromotedPrimaryFallsBack() throws {
        let (args, _) = try buildCommand(RunSelection(
            agent: "claude", template: "tpl", name: nil, clone: false,
            editable: ["/root/B", "/root/A"], readOnly: [], primary: "/root/Z"
        ))
        #expect(args[args.firstIndex(of: "claude")! + 1] == "/root/A")
    }

    @Test("throws when no editable workspace is selected")
    func throwsWhenNoEditableWorkspace() {
        #expect(throws: SbxKitError.noEditableWorkspace) {
            try buildArgs(RunSelection(
                agent: "claude", template: "tpl", name: nil, clone: false,
                editable: [], readOnly: [], primary: nil
            ))
        }
    }

    // PLAN.md: "findAnyConflict — keep as a precondition inside buildArgs.
    // Presets loaded from a hand-edited config still bypass the UI's
    // per-click findCoveringPath check." In the Electron app this was
    // server.mjs's job, checked before buildCommand — that server layer is
    // deleted going native, so buildArgs itself must enforce it now.
    @Test("throws on an overlapping selection between editable and read-only paths")
    func throwsOnOverlappingSelection() {
        #expect(throws: SbxKitError.overlappingSelection(detail: "/root/A/B is inside /root/A")) {
            try buildArgs(RunSelection(
                agent: "claude", template: "tpl", name: nil, clone: false,
                editable: ["/root/A"], readOnly: ["/root/A/B"], primary: nil
            ))
        }
    }

    @Test("an overlap purely within the editable set is also caught")
    func overlapWithinEditableSetIsCaught() {
        #expect(throws: SbxKitError.self) {
            try buildArgs(RunSelection(
                agent: "claude", template: "tpl", name: nil, clone: false,
                editable: ["/root/A", "/root/A/B"], readOnly: [], primary: nil
            ))
        }
    }
}

@Suite("orderedWorkspaces")
struct OrderedWorkspacesTests {
    @Test("primary first, then the rest sorted, excluding a duplicate of primary")
    func primaryFirstThenSorted() {
        #expect(orderedWorkspaces(primary: "/root/A", editable: ["/root/C", "/root/A", "/root/B"])
            == ["/root/A", "/root/B", "/root/C"])
    }
}
