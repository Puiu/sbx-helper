// Ports src/electron/test/command.test.mjs (quotePosix describe block).
import Testing
@testable import SbxKit

@Suite("quotePosix")
struct QuotingTests {
    @Test("leaves a safe path unquoted")
    func leavesSafePathUnquoted() {
        #expect(quotePosix("/path/to/NHO.AccessHub.Web") == "/path/to/NHO.AccessHub.Web")
    }

    @Test("quotes a path containing a space")
    func quotesPathWithSpace() {
        #expect(quotePosix("/path/with space") == "'/path/with space'")
    }

    @Test("escapes an embedded single quote")
    func escapesEmbeddedSingleQuote() {
        let q = quotePosix("/it's/here")
        #expect(q.hasPrefix("'") && q.hasSuffix("'"))
        #expect(q.contains("'\\''"))
    }

    @Test("quotes an empty string")
    func quotesEmptyString() {
        #expect(quotePosix("") == "''")
    }
}

@Suite("formatCommand")
struct FormatCommandTests {
    @Test("joins quoted args with a single space")
    func joinsWithSpace() {
        #expect(formatCommand(["sbx", "run", "/path/with space"]) == "sbx run '/path/with space'")
    }

    @Test("formats an empty argv as an empty string")
    func formatsEmptyArgv() {
        #expect(formatCommand([]) == "")
    }
}
