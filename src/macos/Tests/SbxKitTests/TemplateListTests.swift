// Ports src/electron/test/templates.test.mjs.
import Testing
@testable import SbxKit

@Suite("parseTemplateLs")
struct TemplateListTests {
    @Test("extracts repo:tag pairs and skips the header")
    func extractsRepoTagPairs() {
        let sample = """
        REPOSITORY                              TAG                  IMAGE ID       FLAVOR               CREATED
        docker.io/library/claude-sbx-dotnet10   v2                   e7df4a3fd671   claude-code          About an hour ago
        docker.io/library/claude-sbx-dotnet10   v1                   b9ec0cd15117   claude-code          About an hour ago

        """
        #expect(parseTemplateLs(sample) == [
            "docker.io/library/claude-sbx-dotnet10:v2",
            "docker.io/library/claude-sbx-dotnet10:v1",
        ])
    }

    @Test("handles empty output")
    func handlesEmptyOutput() {
        #expect(parseTemplateLs("") == [])
    }

    @Test("de-duplicates identical repo:tag pairs")
    func deDuplicatesPairs() {
        let sample = """
        REPOSITORY   TAG   IMAGE ID   FLAVOR   CREATED
        repo/a       v1    abc123     flavor   now
        repo/a       v1    def456     flavor   now

        """
        #expect(parseTemplateLs(sample) == ["repo/a:v1"])
    }

    // Regression: `sbx` (or a Docker-compatible CLI on some hosts) can emit
    // CRLF line endings. Swift's Character view merges "\r\n" into a single
    // grapheme cluster, so splitting on the Character "\n" alone would never
    // match — silently collapsing the whole table to one line, which then
    // gets skipped as the header, producing an empty template list with no
    // error (exactly the "you have no templates" failure PLAN.md warns
    // against).
    @Test("handles CRLF line endings")
    func handlesCRLFLineEndings() {
        let sample = "REPOSITORY   TAG   IMAGE ID   FLAVOR   CREATED\r\n"
            + "repo/a       v1    abc123     flavor   now\r\n"
            + "repo/b       v2    def456     flavor   now\r\n"
        #expect(parseTemplateLs(sample) == ["repo/a:v1", "repo/b:v2"])
    }
}
