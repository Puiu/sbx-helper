import Testing
@testable import SbxKit

@Suite("supportedAgents")
struct SupportedAgentsTests {
    @Test("lists all agents from sbx run --help in order")
    func listsAllAgents() {
        #expect(supportedAgents == [
            "claude", "codex", "copilot", "cursor", "devin", "docker-agent",
            "droid", "gemini", "kiro", "opencode", "shell",
        ])
    }
}

@Suite("inferAgent")
struct InferAgentTests {
    @Test("infers claude from the dotnet template name")
    func infersClaude() {
        #expect(inferAgent(fromTemplate: "docker.io/library/claude-sbx-dotnet10:v4") == "claude")
    }

    @Test("infers opencode from its template name")
    func infersOpencode() {
        #expect(inferAgent(fromTemplate: "docker.io/docker/sandbox-templates:opencode-docker") == "opencode")
    }

    @Test("matches case-insensitively")
    func matchesCaseInsensitively() {
        #expect(inferAgent(fromTemplate: "CLAUDE-SBX:v1") == "claude")
    }

    @Test("returns nil when no agent name appears")
    func returnsNilWithoutMatch() {
        #expect(inferAgent(fromTemplate: "my-neutral-template:v1") == nil)
    }

    @Test("earliest occurrence in the template wins on multiple matches")
    func earliestOccurrenceWins() {
        #expect(inferAgent(fromTemplate: "claude-opencode:v1") == "claude")
        #expect(inferAgent(fromTemplate: "opencode-claude:v1") == "opencode")
    }

    @Test("empty template returns nil")
    func emptyTemplateReturnsNil() {
        #expect(inferAgent(fromTemplate: "") == nil)
    }
}
